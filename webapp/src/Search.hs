--{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Search where

import Foundation
import Yesod.Core
import Text.Lucius
import Yesod.Form
import Types
import Data.Text (Text)
import Home
import HooglePlus.Synthesize (synthesize)

import Types.Experiments
import Synquid.Error
import Types.Encoder

-- Imports to remove once mj_benchmark gets merged
import Synquid.Resolver (_environment)--remove later
import Types.Environment (Environment) -- remove later
import Types.Program  (BareDeclaration( .. ), Goal(..), gEnvironment, gSpec)-- remove later
import Text.Parsec.Pos (initialPos)
import Control.Monad.Trans.State.Lazy (evalStateT, evalState)
import qualified Data.ByteString as B -- remove later
import Text.PrettyPrint.ANSI.Leijen.Internal (putDoc, pretty, empty)
import System.Directory (doesFileExist)
import Data.Serialize (decode)
import System.Exit (exitFailure)
import Control.Monad.Trans.Except (runExcept)
import Synquid.Parser (toErrorMessage, parseProgram)
import GHC.Base (when)
import Synquid.Resolver (initResolverState, resolveSchema)
import Text.Parsec.Indent (runIndentParserT)
programName = "hoogleplus" -- remove later

defaultSearchParams = SearchParams {
  _eGuessDepth = 3,
  _sourcePos = noPos,
  _explorerLogLevel = 0,
  _solutionCnt = 1,
  _pathSearch = PetriNet,
  _useHO = False,
  _encoderType = Normal,
  _useRefine = QueryRefinement
}

test = do
    env <- readEnv
    goal <- envToGoal env "a -> a -> a"
    print "before synthezie"
    a <- synthesize defaultSearchParams goal
    print "after synthesize"
    return ()

postSearchR :: Handler Html
postSearchR = do
    -- Move this line below back to Home. HOW CAN I MAKE THIS WORK W/ TOKEN?
    liftIO $ test 
    ((res, formWidget), formEnctype) <- runFormPostNoToken searchForm
    case res of
        FormSuccess _ -> defaultLayout $ do
                            --setTitle "TYGAR Demo | Search"
                            error "hi" 
        FormFailure err -> error (show err)
        FormMissing  -> error "Not Implemented Yet2"

envToGoal :: Environment -> String -> IO Goal
envToGoal env queryStr = do
  let transformedSig = "goal :: " ++ queryStr ++ "\ngoal = ??"
  let parseResult = flip evalState (initialPos "goal") $ runIndentParserT parseProgram () "" transformedSig
  case parseResult of
    Left parseErr -> (putDoc $ pretty $ toErrorMessage parseErr) >> putDoc empty >> error "uh oh"
    Right (funcDecl:decl:_) -> case decl of
      Pos _ (SynthesisGoal id uprog) -> do
        let Pos _ (FuncDecl _ sch) = funcDecl
        let goal = Goal id env sch uprog 3 $ initialPos "goal"
        let spec = runExcept $ evalStateT (resolveSchema (gSpec goal)) (initResolverState { _environment = env })
        case spec of
          Right sp -> return $ goal { gEnvironment = env, gSpec = sp }
          Left parseErr -> (putDoc $ pretty parseErr) >> putDoc empty >> exitFailure

      _ -> error "parse a signature for a none goal declaration"

readEnv :: IO Environment
readEnv = do
    let envPathIn =  "data/env.db" --Main.envPath synquidParams
    doesExist <- doesFileExist envPathIn
    when (not doesExist) (error ("Please run `stack exec -- " ++ programName ++ " generate -p [PACKAGES]` to generate database first"))
    envRes <- decode <$> B.readFile envPathIn
    case envRes of
        Left err -> error err
        Right env -> return env