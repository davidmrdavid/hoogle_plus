{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

module Encoder.DatalogEnc() where

import Data.List
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Monad.State
import Control.Lens

import Encoder.DatalogTypes
import Encoder.ConstraintEncoder (FunctionCode(..))
import qualified Encoder.ConstraintEncoder as CE
import Encoder.Utils
import Types.Common
import Types.Abstract
import Synquid.Pretty

addPlaceVar :: AbstractSkeleton -> Encoder ()
addPlaceVar p = do
    pvar <- gets $ view (variables . place2variable)
    vnbr <- gets $ view (variables . variableNb)
    let p2v = HashMap.insert p vnbr pvar
    let node = Node "place" vnbr
    unless (HashMap.member p pvar) $ do
        modify $ set (variables . place2variable) p2v
        modify $ over (variables . variableNb) (+ 1)

addTransitionVar :: Id -> Encoder ()
addTransitionVar tr = do
    tvar <- gets $ view (variables . trans2variable)
    tnbr <- gets $ view (variables . transitionNb)
    let tr2v = HashMap.insert tr tnbr tvar
    unless (HashMap.member tr tvar) $ do
        modify $ set (variables . trans2variable) tr2v
        modify $ over (variables . variable2trans) (HashMap.insert tnbr tr)
        modify $ over (variables . transitionNb) (+ 1)

assignToken :: AbstractSkeleton -> Int -> Encoder (Int, Int)
assignToken p c = do
    placeMap <- gets $ view (variables . place2variable)
    let pvar = findVariable "place2variable" p placeMap
    return (pvar, c)

setInitialState :: [AbstractSkeleton] -> [AbstractSkeleton] -> Encoder ()
setInitialState inputs places = do
    let nonInputs = filter (`notElem` inputs) places
    let inputCounts = map (\t -> (head t, length t)) (group $ sort inputs)
    let nonInputCounts = map (, 0) nonInputs
    marking <- mapM (uncurry assignToken) (inputCounts ++ nonInputCounts)
    let initMarking = MarkingAt 0 marking
    modify $ set (constraints . initConstraints) initMarking

setFinalState :: AbstractSkeleton -> [AbstractSkeleton] -> Encoder ()
setFinalState ret places = do
    let nonRets = filter ((/=) ret) places
    let nonRetCounts = map (, 0) nonRets
    let counts = (ret, 1) : nonRetCounts
    marking <- mapM (uncurry assignToken) counts
    l <- gets $ view (increments . loc)
    let finalMarking = MarkingAt l marking
    modify $ set (constraints . finalConstraints) finalMarking

disableTransitions :: [Id] -> Encoder ()
disableTransitions trs = do
    transMap <- gets $ view (variables . trans2variable)
    let transMap' = foldr HashMap.delete transMap trs
    modify $ set (variables . trans2variable) transMap'
    -- mapM_ disableTransitionAt trs
    -- where
    --     disableTransitionAt tr = do
    --         transMap <- gets $ view (variables . trans2variable)
    --         let trVar = findVariable "trans2variable" tr transMap
    --         let dis = NotFireAt t trVar
    --         modify $ over (constraints . persistConstraints) (dis :)

addArc :: FunctionCode -> Encoder ()
addArc (FunctionCode f _ params rets) = do
    transMap <- gets $ view (variables . trans2variable)
    let trVar = findVariable "trans2variable" f transMap
    -- add incoming arcs
    let pcnt = map (\l -> (head l, length l)) (group (sort params))
    mapM_ (uncurry $ arcFor In trVar) pcnt
    -- add outgoing arcs
    let rcnt = map (\l -> (head l, length l)) (group (sort rets))
    mapM_ (uncurry $ arcFor Out trVar) rcnt
    where
        arcFor dir tr p c = do
            placeMap <- gets $ view (variables . place2variable)
            let pVar = findVariable "place2variable" p placeMap
            let arc = Arc dir pVar tr c
            modify $ over (constraints . persistConstraints) (arc :)

mustFireTransitions :: Encoder [Constraint]
mustFireTransitions = do
    must <- gets $ view (refinements . mustFirers)
    mapM fireTransition (HashMap.toList must)
    where
        fireTransition (_, tids) = do
            l <- gets $ view (increments . loc)
            transMap <- gets $ view (variables . trans2variable)
            let trVars = map (\tr -> findVariable "trans2variable" tr transMap) tids
            let fireAt = [FireAt t tr | tr <- trVars, t <- [0..(l - 1)]]
            return $ Choices fireAt

encoderInit :: DatalogState
            -> Int
            -> [AbstractSkeleton]
            -> [AbstractSkeleton]
            -> [FunctionCode]
            -> IO DatalogState
encoderInit encoderState len inputs rets sigs =
    execStateT (do
        modify $ set (increments . loc) len
        modify $ set (refinements . returnTyps) rets
        createEncoder inputs (head rets) sigs) encoderState

-- | create a new encoder in z3
createEncoder :: [AbstractSkeleton] -> AbstractSkeleton -> [FunctionCode] -> Encoder ()
createEncoder inputs ret sigs = do
    modify $ set (increments . encodedSigs) sigs
    ty2tr <- gets $ view (variables . type2transition)
    l <- gets $ view (increments . loc)
    let places = HashMap.keys ty2tr
    let transIds = Set.toList $ Set.unions $ HashMap.elems ty2tr

    -- create the type variables
    mapM_ addPlaceVar places
    -- create the transition variables
    mapM_ addTransitionVar transIds
    -- add constraints for pre- and post-conditions
    mapM_ addArc sigs

encoderSolve :: DatalogState -> IO ([Id], DatalogState)
encoderSolve = runStateT solveAndGetModel

solveAndGetModel :: Encoder [Id]
solveAndGetModel = do
    l <- gets $ view (increments . loc)
    prev <- gets $ view (increments . prevChecked)
    when prev $ do
        toBlock <- gets $ view (increments . block)
        modify $ over (constraints . blockConstraints) (toBlock :)
        modify $ set (increments . prevChecked) False
    case solve problem of
        Left err 
            | length rets > 1 -> do
                -- try a more general return type
                t2tr <- gets $ view (variables . type2transition)
                modify $ set (constraints . finalConstraints) []
                modify $ set (refinements . returnTyps) (tail rets)
                modify $ set (increments . prevChecked) False
                setFinalState (rets !! 1) (HashMap.keys t2tr)
                solveAndGetModel
            | otherwise -> liftIO (print err) >> return []
        Right ass -> do
            let transAssignment = map (\(k, i) -> (k, zOf ass i)) (HashMap.toList transMap)
            let transSelected = filter ((==) (Z 1) . snd) transAssignment
            let transitions = map fst transSelected
            let sameTrans = HashMap.filterWithKey (\k _ -> k `elem` transitions) transMap
            let diffTrans = HashMap.difference transMap sameTrans
            -- at least one unselected transition should be fired;
            let unselSum = LZ (zip (HashMap.elems diffTrans) (repeat $ Z 1)) (Z 0)
            let unselChange = unselSum :> c0
            modify $ set (increments . block) unselChange
            return $ map fst $ sortOn snd transitions
    where
        buildVariables = do
            transMap <- gets $ view (variables . trans2variable)
            placeMap <- gets $ view (variables . place2variable)
            let transitions = HashMap.elems transMap
            let places = HashMap.elems placeMap
            let trVars = map (Node "transition") transitions
            let pVars = map (Node "place") places
            return $ trVars ++ pVars

        buildGoal = do
            initial <- gets $ view (constraints . initConstraints)
            final <- gets $ view (constraints . finalConstraints)
            blocks <- gets $ view (constraints . blockConstraints)
            l <- gets $ view (increments . loc)
            let sequences = map (\t -> printf "fire_at(M%d, T%d, M%d)" t t (t + 1)) [0..(l - 1)]
            let constraints = show initial : sequences ++ [show final] ++ map show blocks
                                


-- optimize the optional constraints here:
-- we only need to change the must firers and noTransitionTokens and final states
encoderInc :: [FunctionCode] -> [AbstractSkeleton] -> [AbstractSkeleton] -> Encoder ()
encoderInc sigs inputs rets = do
    persists <- gets $ view (constraints . persistConstraints)
    modify $ over (increments . loc) (+ 1)
    modify $ set (refinements . returnTyps) rets
    modify $ set constraints ( emptyConstraints { _persistConstraints = persists })
    ty2tr <- gets $ view (variables . type2transition)
    l <- gets $ view (increments . loc)
    toRemove <- gets $ view (refinements . disabledTrans)
    -- disable transitions at the new timestamp
    disableTransitions toRemove (l - 1)

encoderRefine :: SplitInfo 
              -> [AbstractSkeleton] 
              -> [AbstractSkeleton] 
              -> [FunctionCode] 
              -> Encoder ()
encoderRefine info inputs rets newSigs = do
    {- update the abstraction level -}
    modify $ over (refinements . disabledTrans) (++ removedTrans info)
    modify $ over (increments . encodedSigs) (++ newSigs)
    modify $ set (refinements . returnTyps) rets

    {- operation on places -}
    l <- gets $ view (increments . loc)
    t2tr <- gets $ view (variables . type2transition)
    sigs <- gets $ view (increments . encodedSigs)
    let newPlaceIds = newPlaces info
    let newTransIds = newTrans info
    let currPlaces = HashMap.keys t2tr
    let newTrans = [(tr, t) | t <- [0..(l-1)], tr <- newSigs ]
    let allTrans = [(funName tr, t) | t <- [0..(l-1)], tr <- sigs ]

    -- add new place variables
    mapM_ addPlaceVar newPlaceIds
    -- add new transition variables
    mapM_ addTransitionVar newTransIds
    -- refine the precondition constraints
    mapM_ addArc newSigs
    -- disable splitted transitions
    mapM_ (disableTransitions (removedTrans info)) [0..(l-1)]

instance CE.ConstraintEncoder DatalogState where
    encoderInit = encoderInit
    encoderInc sigs inputs rets = execStateT (encoderInc sigs inputs rets)
    encoderRefine info inputs rets newSigs = execStateT (encoderRefine info inputs rets newSigs)
    encoderSolve = encoderSolve

    emptyEncoder = emptyDatalogState
    getTy2tr enc = enc ^. variables . type2transition
    setTy2tr m = variables . type2transition .~ m
    modifyTy2tr f = variables . type2transition %~ f
    setPrevChecked c = increments . prevChecked .~ c
    modifyMusters f = refinements . mustFirers %~ f
    setParams p = encSearchParams .~ p