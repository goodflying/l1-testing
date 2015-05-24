{-# OPTIONS_GHC -Wall #-}
{-# Language TypeFamilies #-}
{-# Language ScopedTypeVariables #-}
{-# Language FlexibleContexts #-}
{-# Language DeriveGeneric #-}
{-# Language DeriveFunctor #-}
{-# Language RecordWildCards #-}

module L1.L1
       ( L1States(..)
       , FullSystemState(..)
       , L1Params(..)
       , WQS(..)
       , prepareL1
       , integrate
       , integrate'
       ) where

import GHC.Generics ( Generic, Generic1 )

import qualified Numeric.GSL.ODE as ODE
import qualified Numeric.LinearAlgebra.Data as D
import qualified Data.Vector as V
import qualified Data.Vector.Storable as SV

import Casadi.CMatrix ( CMatrix )
import Casadi.SX ( SX )
import Casadi.DMatrix ( DMatrix )
import Casadi.MX ( MX )
import Casadi.Overloading ( SymOrd(..) )

import Accessors

import Dyno.Vectorize
import Dyno.View.M ( M, ms, mm, trans, uncol, col, hsplitTup )
import Dyno.View.Viewable
import Dyno.View.JV
import Dyno.View.Fun
import Dyno.View.FunJac
import Dyno.View.View

dot :: (View f, CMatrix a) => M f (JV Id) a -> M f (JV Id) a -> M (JV Id) (JV Id) a
dot x y = trans x `mm` y

{-

Basic equations

xdot = Am x + b (mu + theta^T x + sigma0)
y = c^T x

mu = F u


etahat = omegahat u + thetahat^T x + sigmahat

xhatdot = Am xhat + b etahat
yhat = c^T xhat

omegahatdot = Gamma Proj(omegahat, -xtilde^T P b u)
thetahatdot = Gamma Proj(thetahat, -xtilde^T P b x)
sigmahatdot = Gamma Proj(sigmahat, -xtilde^T P b)

u = -k D (etahat - kg r)

p-}

--rscale :: Container c e
--rscale = flip scale

{-

The Proj(theta, err) operator.

Pages 291-294 describe this projection operator.  For a long time I
was confused by the "Gamma Proj(theta, err)" notation, and I
thought the Gamma belonged inside the projection operator.  It
turns out it's not quite just hard-bounding the parameter
estimates; it does keep them in the valid range, but this operator
needs to be smooth for the Lyapunov proofs.

-}
fproj :: (View x, Viewable a, CMatrix a) => S a -> S a -> M x (JV Id) a -> S a
fproj etheta thetamax theta =
  ((etheta + 1) * theta `dot` theta - maxsq) / (etheta * maxsq)
  where
    maxsq = thetamax `dot` thetamax

gradfproj :: (View x, Viewable a, CMatrix a) => S a -> S a -> M x (JV Id) a -> M x (JV Id) a
gradfproj etheta thetamax theta =
  (2 * (etheta + 1) / (etheta + maxsq)) `scale` theta
  where
    maxsq = thetamax `dot` thetamax

gt :: (Num a, SymOrd a) => a -> a -> a
gt x y = 1 - (x `leq` y)

-- todo(move this and its friend to SymOrd (casadi bindings))
--lt :: (Num a, SymOrd a) => a -> a -> a
--lt x y = 1 - (x `geq` y)

proj :: forall x a
        . (View x, Viewable a, CMatrix a, SymOrd (M x (JV Id) a))
        => S a -> S a -> M x (JV Id) a -> M x (JV Id) a -> M x (JV Id) a
proj etheta thetamax theta signal =
  signal - (1 - aOk) `scale` (ft `scale` (dfty `scale` df))
  where
    aOk :: S a
    aOk = (ft `geq` 0)*(dfty `gt` 0)
    ft :: S a
    ft = fproj etheta thetamax theta
    df :: M x (JV Id) a
    df = gradfproj etheta thetamax theta
    dfty :: S a
    dfty = df `dot` signal


--etheta0 :: Fractional a => a
--etheta0 = 0.1

{-

Low-pass filter

-}
dstep :: (CMatrix a, Viewable a) => S a -> S a -> S a -> S a
dstep w u y = ydot
  where
    ydot = w * (u - y)

scale :: (Viewable a, CMatrix a, View f, View g) => S a -> M f g a -> M f g a
scale s m = m `ms` (uncol s)

{-

Discrete L1 controller step

-}


data L1States x a =
  L1States
  { l1sXhat :: x a
  , l1sU :: a
  , l1sWqsHat :: WQS x a
  } deriving (Functor, Generic, Generic1, Show)
instance Vectorize x => Vectorize (L1States x)
instance (Lookup a, Lookup (x a)) => Lookup (L1States x a)

data WQS x a =
  WQS
  { wqsOmega :: a
  , wqsTheta :: x a
  , wqsSigma :: a
  } deriving (Functor, Generic, Generic1, Show)
instance Vectorize x => Vectorize (WQS x)
instance (Lookup a, Lookup (x a)) => Lookup (WQS x a)

data FullSystemState x a =
  FullSystemState
  { ffsX :: x a
  , ffsWQS :: WQS x a
  } deriving (Functor, Generic, Generic1)
instance Vectorize x => Vectorize (FullSystemState x)

data FullL1State x a =
  FullL1State
  { controllerState :: J (JV (L1States x)) a
  , systemState :: J (JV (FullSystemState x)) a
  } deriving (Generic, Generic1)
instance Vectorize x => View (FullL1State x)

data L1Params x a =
  L1Params
  { l1pETheta0 :: S a
  , l1pOmegaMax :: S a
  , l1pSigmaMax :: S a
  , l1pThetaMax :: S a
  , l1pGamma :: S a
  , l1pKg :: S a
  , l1pP :: M x x a
  , l1pW :: S a
  } deriving Functor


type S a = M (JV Id) (JV Id) a

prepareL1 ::
  forall x u
  . (Vectorize x, u ~ Id)
  => (FullSystemState x (J (JV Id) SX) -> J (JV Id) SX -> x (J (JV Id) SX))
  -> L1Params (JV x) MX -- todo(symbolic leak)
  -> IO (FullSystemState x Double -> L1States x Double -> Double -> IO (L1States x Double, x Double))
prepareL1 userOde l1params = do
  let f :: JacIn (JTuple (JV x) (JV u)) (J (JV (WQS x))) SX -> JacOut (JV x) (J JNone) SX
      f (JacIn xu wqs) = JacOut (catJV' xdot) (cat JNone)
        where
          xdot :: x (J (JV Id) SX)
          xdot = userOde ffs u

          ffs :: FullSystemState x (J (JV Id) SX)
          ffs =
            FullSystemState
            { ffsX = splitJV' x
            , ffsWQS = splitJV' wqs
            }

          JTuple x u = split xu

  sxF <- toSXFun "user ode" f
  userJac <- toFunJac sxF

  let fullOde :: JTuple (FullL1State x) (JV Id) MX -> JTuple (JV (L1States x)) (JV x) MX
      fullOde (JTuple fullL1States r) = JTuple l1dot x'
        where
          l1dot = ddtL1States l1params dx'dx dx'du (col r) x (catJV' controllerState')

          FullL1State{..} = split fullL1States
          controllerState'@(L1States{..}) = splitJV' controllerState

          --jacIn :: JacIn (JTuple f0 (JV Id)) (WQS x) (J (JV Id) MX)
          jacIn = JacIn (cat (JTuple (catJV' l1sXhat) (catJV' (Id l1sU)))) (catJV' l1sWqsHat)
          dx'dxu :: M (JV x) (JTuple (JV x) (JV u)) MX
          x' :: J (JV x) MX
          Jac dx'dxu x' _ = call userJac jacIn

          dx'dx :: M (JV x) (JV x) MX
          dx'du :: M (JV x) (JV u) MX
          (dx'dx, dx'du) = hsplitTup dx'dxu

          x :: M (JV x) (JV Id) MX
          x = col $ catJV' (ffsX (splitJV' systemState))

  fullOdeMX <- toMXFun "full ode with l1" fullOde

  let retFun :: FullSystemState x Double -> L1States x Double -> Double
                -> IO (L1States x Double, x Double)
      retFun ffs l1States r = do
        let fullL1States :: FullL1State x DMatrix
            fullL1States =
              FullL1State
              { controllerState = v2d $ catJV l1States
              , systemState = v2d $ catJV ffs
              }
            input = JTuple (cat fullL1States) (v2d (catJV (Id r)))
        JTuple ret x' <- eval fullOdeMX input
        return (splitJV (d2v ret), splitJV (d2v x'))

  return retFun


ddtL1States ::
  forall a x
  . (Vectorize x, Viewable a, CMatrix a)
  => L1Params (JV x) a
  -> M (JV x) (JV x) a -- am
  -> M (JV x) (JV Id) a -- b
  -> S a
  -> M (JV x) (JV Id) a
  -> J (JV (L1States x)) a -> J (JV (L1States x)) a
ddtL1States L1Params{..} am b r x l1states =
  catJV' $ L1States (splitJV' (uncol xhatdot)) (unId (splitJV' (uncol udot))) wqsDot
  where
    L1States xhat0 u0 wqsHat' = splitJV' l1states

    xhat :: M (JV x) (JV Id) a
    xhat = col (catJV' xhat0)

    u :: M (JV Id) (JV Id) a
    u = col u0

    wqsDot :: WQS x (J (JV Id) a)
    wqsDot =
      WQS
      { wqsOmega = unId $ splitJV' (uncol omegahatdot)
      , wqsTheta =        splitJV' (uncol thetahatdot)
      , wqsSigma = unId $ splitJV' (uncol sigmahatdot)
      }

    wqsHat :: WQS x (J (JV Id) a)
    wqsHat = wqsHat'
    omegahat :: M (JV Id) (JV Id) a
    omegahat = col (catJV' (Id (wqsOmega wqsHat)))
    thetahat :: M (JV x) (JV Id) a
    thetahat = col (catJV' (wqsTheta wqsHat))
    sigmahat :: M (JV Id) (JV Id) a
    sigmahat = col (catJV' (Id (wqsSigma wqsHat)))

    -- Compute error between reference model and true state
    xtilde :: M (JV x) (JV Id) a
    xtilde = xhat - x
    -- Update parameter estimates.  The estimate derivatives we
    -- compute here will be used to form the next step's estimates; we
    -- use the values we receive as arguments for everything at this
    -- step.
    xtpb :: S a
    xtpb = (-(trans xtilde)) `mm` l1pP `mm` b

    gp :: View f => S a -> M f (JV Id) a -> M f (JV Id) a -> M f (JV Id) a
    gp somethingMax th sig = l1pGamma `scale` proj l1pETheta0 somethingMax th sig

    omegahatdot,sigmahatdot :: S a
    omegahatdot = gp l1pOmegaMax omegahat (xtpb `scale` u)
    sigmahatdot = gp l1pSigmaMax sigmahat xtpb
    thetahatdot :: M (JV x) (JV Id) a
    thetahatdot = gp l1pThetaMax thetahat (xtpb `scale` x)
    -- Update reference model state using the previous values.  The
    -- 'xhat' value we receive should be the model's prediction (using
    -- the previous xhat and xhatdot) for the true state 'x' at this
    -- timestep.

    eta :: S a
    eta = omegahat * u + thetahat `dot` x + sigmahat

    xhatdot :: M (JV x) (JV Id) a
    xhatdot = am `mm` xhat + eta `scale` b
    -- Update the reference LPF state
    e :: S a
    e = l1pKg * r - eta

    udot :: S a
    udot = dstep l1pW e u

integrate :: Vectorize x => (x Double -> x Double) -> Double -> x Double -> x Double
integrate f h x0 = devectorize $ sv $ last sol
  where
    vs :: V.Vector Double -> SV.Vector Double
    vs = SV.fromList .  V.toList
    sv :: SV.Vector Double -> V.Vector Double
    sv =  V.fromList . SV.toList

    sol = D.toRows $
          ODE.odeSolveV
          ODE.MSAdams
          h 1e-7 1e-5 f'
          (vs (vectorize x0))
          (SV.fromList [0, h])
    f' :: Double -> SV.Vector Double -> SV.Vector Double
    f' _ x = vs $ vectorize $ f (devectorize (sv x))


integrate' :: Vectorize x => (x Double -> x Double) -> Double -> [Double] -> x Double -> [x Double]
integrate' f h times x0 = map (devectorize . sv) sol
  where
    vs :: V.Vector Double -> SV.Vector Double
    vs = SV.fromList .  V.toList
    sv :: SV.Vector Double -> V.Vector Double
    sv =  V.fromList . SV.toList

    sol = D.toRows $
          ODE.odeSolveV
          ODE.MSAdams
          h 1e-7 1e-5 f'
          (vs (vectorize x0))
          (SV.fromList times)
    f' :: Double -> SV.Vector Double -> SV.Vector Double
    f' _ x = vs $ vectorize $ f (devectorize (sv x))
