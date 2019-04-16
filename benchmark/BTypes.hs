{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
module BTypes where

import Types.Environment
import Types.Experiments

import GHC.Generics
import GHC.Exception
import Data.Aeson hiding (Result)
import Data.Data
import Data.Typeable

data Args = Args {
  argsQueryFile :: String,
  argsTimeout :: Int, -- Timeout in seconds
  argsOutputFile :: Maybe FilePath
  } deriving (Show, Data, Typeable)

data ExperimentSetup = ExpSetup {
  expTimeout :: Int -- Timeout in seconds
  }

type Experiment = (Environment, String, Query, SearchParams, String)

data Query = Query {
  name :: String,
  query :: String
  } deriving (Generic, Show)

instance FromJSON Query

data ResultSummary = ResultSummary {
  envName :: String,
  paramName :: String,
  queryName :: String,
  queryStr :: String,
  result :: Either EvaluationException Result
  } deriving (Show)

data Result = Result {
  resSolution :: String,
  resTFirstSoln :: Double,
  resTEncFirstSoln :: Double,
  resLenFirstSoln :: Int,
  resRefinementSteps :: Int,
  resTransitions :: Int,
  resTypes :: Int
  } deriving (Show, Eq)

data EvaluationException =
  TimeoutException
  | RuntimeException SomeException

instance Show EvaluationException where
  show (TimeoutException) = "Timeout"
  show (RuntimeException _) = "Runtime error"
instance Exception EvaluationException
