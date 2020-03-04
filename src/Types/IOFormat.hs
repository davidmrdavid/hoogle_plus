{-# LANGUAGE DeriveGeneric, DeriveDataTypeable #-}

module Types.IOFormat where

import Types.Type

import GHC.Generics
import Data.Aeson
import Data.Serialize
import Data.Data

outputPrefix = "RESULTS:"

data QueryType = SearchPrograms
               | SearchTypes
               | SearchResults
               | SearchExamples
  deriving(Eq, Data, Show, Generic)

instance FromJSON QueryType
instance ToJSON QueryType

data Example = Example {
    inputs :: [String],
    output :: String
} deriving(Eq, Generic)

instance Show Example where
    show e = unwords [unwords (inputs e), "==>", output e]

instance ToJSON Example
instance FromJSON Example
instance Serialize Example

type ErrorMessage = String
type TypeQuery = String

data QueryInput = QueryInput {
    query :: TypeQuery,
    inExamples :: [Example]
} deriving(Eq, Show, Generic)

instance FromJSON QueryInput

data QueryOutput = QueryOutput {
    solution :: String,
    outExamples :: [Example],
    outError :: String
} deriving(Eq, Generic)

instance ToJSON QueryOutput

data ExecInput = ExecInput {
    execQuery :: TypeQuery,
    execArgs :: [String],
    execProg :: String
} deriving(Eq, Generic)

instance FromJSON ExecInput

data ExecOutput = ExecOutput {
    execError :: String,
    execResult :: String
} deriving(Eq, Generic)

instance ToJSON ExecOutput

data ExamplesInput = ExamplesInput {
    exampleQuery :: TypeQuery,
    exampleProgram :: String,
    exampleExisting :: [Example]
} deriving(Eq, Generic)

instance FromJSON ExamplesInput

data ListOutput a = ListOutput {
    examplesOrTypes :: [a],
    tqError :: String
} deriving(Eq, Generic)

instance ToJSON a => ToJSON (ListOutput a)