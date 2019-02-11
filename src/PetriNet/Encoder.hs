module PetriNet.Encoder where

import Data.Maybe
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Z3.Base as Z3
import Z3.Monad hiding(Z3Env, newEnv)

import PetriNet.PNBuilder
import Synquid.Util

data VarType = VarPlace | VarTransition | VarFlow | VarTimestamp
    deriving(Eq, Ord, Show)

data Variable = Variable {
  varId :: Int,
  varName :: String,
  varTimestamp :: Int,
  varValue :: Int,
  varType :: VarType
} deriving(Eq, Ord, Show)

data Z3Env = Z3Env {
  envSolver  :: Z3.Solver,
  envContext :: Z3.Context,
  envOptimize :: Z3.Optimize
}

data EncodeState = EncodeState {
  z3env :: Z3Env,
  petriNet :: PetriNet,
  loc :: Int,
  abstractionLv :: Int,
  transitionNb :: Int,
  lv2range :: HashMap Int (Int, Int),
  place2variable :: HashMap (Id, Int) Variable, -- place name and timestamp
  time2variable :: HashMap (Int, Int) Variable, -- timestamp and abstraction level
  transition2id :: HashMap Int (HashMap Id Int), -- transition name and abstraction level
  id2transition :: HashMap Int (Id, Int),
  mustFirers :: [Id],
  transitionChildren :: HashMap Id [Id],
  transitionParents :: HashMap Id [Id]
}

newEnv :: Maybe Logic -> Opts -> IO Z3Env
newEnv mbLogic opts =
  Z3.withConfig $ \cfg -> do
    setOpts cfg opts
    ctx <- Z3.mkContext cfg
    opt <- Z3.mkOptimize ctx
    solver <- maybe (Z3.mkSolver ctx) (Z3.mkSolverForLogic ctx) mbLogic
    return $ Z3Env solver ctx opt

initialZ3Env = newEnv Nothing stdOpts
