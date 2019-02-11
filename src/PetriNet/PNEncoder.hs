{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module PetriNet.PNEncoder(
      EncodeState(..)
    , SplitInfo(..)
    , encoderInit
    , encoderSolve
    , encoderRefine
    ) where

import Data.Maybe
import Data.List
import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Set as Set
import Z3.Monad hiding(Z3Env, newEnv)
import qualified Z3.Base as Z3
import Control.Monad.State
import System.CPUTime
import Text.Printf

import PetriNet.PNBuilder
import PetriNet.Encoder
import PetriNet.AbstractType
import Synquid.Util

type Encoder = StateT EncodeState IO

instance MonadZ3 Encoder where
    getSolver = gets (envSolver . z3env)
    getContext = gets (envContext . z3env)
    getOptimize = gets (envOptimize . z3env)

-- | create a new encoder in z3
createEncoder :: [Id] -> Id -> Encoder ()
createEncoder inputs ret = do
    -- create all the type variables for encoding
    createVariables
    -- add all the constraints for the solver
    createConstraints
    -- set initial and final state for solver
    places <- pnPlaces . petriNet <$> get
    setInitialState inputs places
    setFinalState ret places

-- | set the initial state for the solver, where we have tokens only in void or inputs
-- the tokens in the other places should be zero
setInitialState :: [Id] -> HashMap Id Place -> Encoder ()
setInitialState inputs places = do
    let nonInputs = HashMap.filterWithKey (\k _ -> notElem k inputs) places
    mapM_ emptyOther $ HashMap.elems nonInputs
    -- assign tokens to each input types
    mapM_ (uncurry assignToken) inputCounts
  where
    inputCounts = map (\t -> (head t, length t)) $ group $ sort inputs
    assignToken t v = do
        places <- pnPlaces . petriNet <$> get
        placeMap <- place2variable <$> get
        let p = findVariable t places
        tVar <- mkZ3IntVar $ findVariable (placeId p, 0) placeMap
        mkIntNum v >>= mkEq tVar >>= assert
    emptyOther p = do 
        placeMap <- place2variable <$> get
        let v = if placeId p == "void" then 1 else 0
        tVar <- mkZ3IntVar $ findVariable (placeId p, 0) placeMap
        mkIntNum v >>= mkEq tVar >>= assert

-- | set the final solver state, we allow only one token in the return type
-- and maybe several tokens in the "void" place
setFinalState :: Id -> HashMap Id Place -> Encoder ()
setFinalState ret places = do
    -- the return value should have only one token
    includeRet
    -- other places excluding void and ret should have nothing
    let nonOutputs = HashMap.filterWithKey (\k _ -> k /= ret) places
    mapM_ excludeOther $ HashMap.elems nonOutputs
  where
    includeRet = do
        placeMap <- place2variable <$> get
        places <- pnPlaces . petriNet <$> get
        let retPlace = findVariable ret places
        l <- loc <$> get
        retVar <- mkZ3IntVar $ findVariable (placeId retPlace, l) placeMap
        mkIntNum 1 >>= mkEq retVar >>= assert
    excludeOther p = do
        l <- loc <$> get
        placeMap <- place2variable <$> get
        when (placeId p /= "void") $ do
            tVar <- mkZ3IntVar $ findVariable (placeId p, l) placeMap
            mkIntNum 0 >>= mkEq tVar >>= assert

solveAndGetModel :: Encoder [(Id, Int)]
solveAndGetModel = do
    res <- check
    l <- loc <$> get
        {- when (l == 4) (do
        solverStr <- solverToString
        liftIO $ putStrLn solverStr
        transMap <- transition2id <$> get
        liftIO $ print transMap
                  ) -}
    case res of
        Sat -> do
            model <- solverGetModel
            selected <- mapM (checkLit model) [0..(l-1)]
            blockTrs <- mapM (uncurry blockTr) (zip [0..(l-1)] selected)
            -- placeMap <- place2variable <$> get
            -- blockP <- mapM (checkIntLit model) $ HashMap.toList placeMap
            mkAnd blockTrs >>= mkNot >>= assert
            selectedNames <- getTrNames selected
            return (zip selectedNames [0,1..])
        Unsat -> do
            liftIO $ print "unsat"
            return []
        Undef -> do
            liftIO $ print "undef"
            return []
  where
    getTrNames selected = do
        lv <- abstractionLv <$> get
        transMap <- id2transition <$> get
        let transNames = map (\id -> findVariable (fromIntegral id) transMap) selected
        let selectedTrs = map fst (filter ((==) lv . snd) transNames)
        return selectedTrs

    checkLit model t = do
        lv <- abstractionLv <$> get
        tsMap <- time2variable <$> get
        tsVar <- mkZ3IntVar (findVariable (t, lv) tsMap)
        bMay <- evalInt model tsVar
        case bMay of
            Just b -> return b
            Nothing -> error $ "cannot eval the variable" ++ show (t, lv)

    blockTr t tr = do
        lv <- abstractionLv <$> get
        tsMap <- time2variable <$> get
        tsVar <- mkZ3IntVar (findVariable (t, lv) tsMap)
        mkIntNum tr >>= mkEq tsVar

    checkIntLit model (k, v) = do
        pVar <- mkZ3IntVar v
        iMay <- eval model pVar
        case iMay of
            Just i -> mkEq pVar i
            Nothing -> error $ "cannot eval the variable" ++ show k

encoderInit :: PetriNet -> Int -> [Id] -> [Id] -> Id -> IO EncodeState
encoderInit net loc hoArgs inputs ret = do
    z3Env <- initialZ3Env
    let initialState = EncodeState z3Env net loc 0 0 HashMap.empty HashMap.empty HashMap.empty HashMap.empty HashMap.empty hoArgs HashMap.empty HashMap.empty
    execStateT (createEncoder inputs ret) initialState

encoderSolve :: EncodeState -> IO ([(Id, Int)], EncodeState)
encoderSolve st = runStateT solveAndGetModel st

data SplitInfo = SplitInfo {
    oldPlace :: AbstractSkeleton,
    newPlace :: [AbstractSkeleton],
    splitedGroup :: [(Id, [Id])]
} deriving (Eq, Ord, Show)

updateParallelInfo :: SplitInfo -> Encoder ()
updateParallelInfo info = do
    trChd <- transitionChildren <$> get
    trPar <- transitionParents <$> get
    let splitTrans = splitedGroup info
    let trChd' = foldr (uncurry updateChildren) trChd splitTrans
    let trPar' = foldr (uncurry updateParents) trPar splitTrans
    st <- get
    put $ st { transitionParents = trPar'
             , transitionChildren = trChd' }
  where
    updateChildren splitedTrans splitToTrans transMap = 
        let includeSplited = HashMap.filter (elem splitedTrans) transMap
            fold_fun k _ = HashMap.insertWith (++) k splitToTrans
            transMap' = HashMap.foldrWithKey fold_fun transMap includeSplited
        in HashMap.insertWith (++) splitedTrans splitToTrans transMap'

    updateParents splitedTrans splitToTrans transMap =
        let parents = HashMap.lookupDefault [] splitedTrans transMap
            fold_fun tid m = HashMap.insertWith (++) tid (splitedTrans:parents) m
        in foldr fold_fun transMap splitToTrans

-- | wrap some action with time measuring and print out the execution time
withTime :: String -> Encoder a -> Encoder a
withTime desc f = do
    start <- liftIO getCPUTime
    res <- f
    end <- liftIO getCPUTime
    let diff = (fromIntegral (end - start)) / (10^12)
    -- let time = printf "%s time: %0.3f sec\n" desc (diff :: Double)
    -- liftIO $ putStrLn time
    return res

encoderRefine :: PetriNet -> SplitInfo -> [Id] -> Id -> Encoder ()
encoderRefine net info inputs ret = do
    -- update the transition hierarchy information
    -- updateParallelInfo info
    -- put the new petri net into the state
    st <- get
    put $ st { petriNet = net 
             , abstractionLv = (abstractionLv st + 1)
             }
    let splitedTyp = show (oldPlace info)
    let typIds = map show (newPlace info)
    let splitedPlace = fromJust (HashMap.lookup splitedTyp (pnPlaces net))
    let newPlaces = map (\nt -> fromJust (HashMap.lookup nt (pnPlaces net))) typIds
    let inputClones = map (\n -> n ++ "|clone") inputs
    let transIds = concat (snd (unzip (splitedGroup info)))
    let allTransIds = fst (unzip (splitedGroup info)) ++ transIds
    -- some of the transitions are splitted
    let newTrans = map (\tr -> fromJust (HashMap.lookup tr (pnTransitions net))) (inputClones ++ transIds)
    -- other transition have no change but need to be copied to the next level
    let noSplit k _ = not (elem k allTransIds || "|clone" `isSuffixOf` k)
    let oldTransIds = HashMap.keys (HashMap.filterWithKey noSplit (findVariable (abstractionLv st) (transition2id st)))
    let oldTrans = map (\tr -> findVariable tr (pnTransitions net)) oldTransIds
    let lookupTrans tr = fromJust (HashMap.lookup tr (pnTransitions net))
    let splitTrans = map (\(tr, trs) -> (lookupTrans tr, map lookupTrans trs)) (splitedGroup info)

    l <- loc <$> get
    let allTrans = [(t, tr) | t <- [0..(l-1)], tr <- newTrans ]

    -- add new place, transition and timestamp variables
    mapM_ addPlaceVar newPlaces
    addTransitionVar (newTrans ++ oldTrans)
    mapM_ addTimestampVar [0..(l-1)]

    -- refine the sequential constraints
    -- but enable transitions between abstraction levels fired simultaneously
    -- let transitions = HashMap.elems (pnTransitions net)
    -- mapM_ (fireAt transitions) [0..(l-1)]
    withTime "sequentialTransitions" sequentialTransitions

    -- refine the precondition constraints
    withTime "preconditions" $ mapM_ (uncurry preconditionsTransitions) allTrans

    -- refine the postcondition constraints
    withTime "postconditions" $ mapM_ (uncurry postconditionsTransitions) allTrans

    -- refine the no transition constraints
    withTime "placeMerge" $ mapM_ (placeMerge splitedPlace newPlaces) [0..l]
    withTime "transMerge" $ mapM_ (uncurry transMerge) [ (tr, t) | tr <- splitTrans, t <- [0..(l-1)] ]
    withTime "transKeep" $ mapM_ (uncurry transClone) [ (tr, t) | tr <- oldTrans, t <- [0..(l-1)] ]
    withTime "noTransitionTokens" $ mapM_ (uncurry noTransitionTokens) [(t, p) | p <- newPlaces, t <- [0..(l-1)]]

    -- refine the must firers
    withTime "mustFireTransitions" mustFireTransitions

    -- set new initial and final state
    let newPmap = HashMap.filterWithKey (\k _ -> k `elem` typIds) (pnPlaces net)
    setInitialState inputs newPmap
    setFinalState ret newPmap
  where
    
    placeMerge p nps t = do
        placeMap <- place2variable <$> get
        let npVars = map (\np -> findVariable (placeId np, t) placeMap) nps
        npZ3Vars <- mapM mkZ3IntVar npVars
        let pVar = findVariable (placeId p, t) placeMap
        pZ3Var <- mkZ3IntVar pVar
        mkAdd npZ3Vars >>= mkEq pZ3Var >>= assert

    transMerge (tr, ntrs) t = do
        transMap <- transition2id <$> get
        tsMap <- time2variable <$> get
        lv <- abstractionLv <$> get
        let ntrIds = map (\ntr -> findVariable (transitionId ntr) (findVariable lv transMap)) ntrs
        let trId = findVariable (transitionId tr) (findVariable (lv - 1) transMap)
        let tsVar = findVariable (t, lv) tsMap
        let lastTsVar = findVariable (t, lv - 1) tsMap
        tsZ3Var <- mkZ3IntVar tsVar
        lastTsZ3Var <- mkZ3IntVar lastTsVar
        selectTr <- mkIntNum trId >>= mkEq lastTsZ3Var 
        selectNtrs <- mapM mkIntNum ntrIds >>= mapM (mkEq tsZ3Var)
        mkOr selectNtrs >>= mkIff selectTr >>= assert

    transClone tr t = do
        transMap <- transition2id <$> get
        tsMap <- time2variable <$> get
        lv <- abstractionLv <$> get
        trVar <- mkIntNum (findVariable (transitionId tr) (findVariable lv transMap))
        lastTrVar <- mkIntNum (findVariable (transitionId tr) (findVariable (lv - 1) transMap))
        tsVar <- mkZ3IntVar (findVariable (t, lv) tsMap)
        lastTsVar <- mkZ3IntVar (findVariable (t, lv - 1) tsMap)
        selectLastTr <- mkEq lastTsVar lastTrVar
        selectTr <- mkEq tsVar trVar
        mkIff selectLastTr selectTr >>= assert

addPlaceVar ::  Place -> Encoder ()
addPlaceVar p = do
    l <- loc <$> get
    mapM_ addPlaceVarAt [0..l]
  where
    addPlaceVarAt t = do
        st <- get
        let placeVar = Variable 0 (placeId p ++ "_" ++ show t) t 0 VarPlace
        put $ st { place2variable = HashMap.insert (placeId p, t) 
                                                    placeVar 
                                                   (place2variable st)
                 }

-- | add transition mapping from (tr, lv) to integer id
addTransitionVar :: [Transition] -> Encoder ()
addTransitionVar trs = do
    lv <- abstractionLv <$> get
    start <- transitionNb <$> get -- inclusive start
    mapM_ addTransitionVarFor trs
    end <- transitionNb <$> get -- exclusive end
    st <- get
    put $ st { lv2range = HashMap.insert lv (start, end) (lv2range st) }
  where
    addTransitionVarFor tr = do
        lv <- abstractionLv <$> get
        st <- get
        let tid = transitionNb st
        -- liftIO $ putStrLn $ show tid ++ ": " ++ show (transitionId tr)
        put $ st { transitionNb = 1 + transitionNb st
                 , transition2id = HashMap.insertWith HashMap.union lv (HashMap.singleton (transitionId tr) tid) (transition2id st)
                 , id2transition = HashMap.insert tid (transitionId tr, lv) (id2transition st)
                 }

addTimestampVar :: Int -> Encoder ()
addTimestampVar t = do
    absLv <- abstractionLv <$> get
    mapM_ addTimestampVarAt [0..absLv]
  where
    addTimestampVarAt l = do
        st <- get
        let tsVar = Variable (-1) ("ts_" ++ show t ++ "_" ++ show l) t l VarTimestamp
        put $ st { time2variable = HashMap.insert (t, l) tsVar (time2variable st) }

-- | map each place and transition to a variable in z3
createVariables ::  Encoder ()
createVariables = do
    pn <- petriNet <$> get
    l <- loc <$> get
    -- lv <- abstractionLv <$> get
    -- add place variables
    mapM_ addPlaceVar (pnPlaces pn)
    -- add transition mapping
    addTransitionVar (HashMap.elems (pnTransitions pn))
    -- add timestamp variables
    mapM_ addTimestampVar [0..(l-1)]

createConstraints ::  Encoder ()
createConstraints = do
    -- prepare constraint parameters
    l <- loc <$> get
    trans <- HashMap.elems . pnTransitions . petriNet <$> get
    places <- HashMap.elems . pnPlaces . petriNet <$> get
    let allTrans = [(t, tr) | t <- [0..(l-1)], tr <- trans]
    let allPlaces = [(t, p) | t <- [0..(l-1)], p <- places]

    -- we assume we only have the first abstraction level each time when we call this method
    sequentialTransitions
    -- we do not have parallel transitions in the first time encoding
    
    mapM_ (uncurry preconditionsTransitions) allTrans

    mapM_ (uncurry postconditionsTransitions) allTrans

    mapM_ (uncurry noTransitionTokens) allPlaces

    mustFireTransitions

mkZ3BoolVar ::  Variable -> Encoder AST
mkZ3BoolVar var = do
    varSymbol <- mkIntSymbol (varId var)
    boolS <- mkBoolSort
    const <- mkConst varSymbol boolS
    return const

mkZ3IntVar :: Variable -> Encoder AST
mkZ3IntVar var = do
    varSymbol <- mkStringSymbol (varName var)
    intS <- mkIntSort
    const <- mkConst varSymbol intS
    return const

findVariable :: (Eq k, Hashable k, Show k) => k -> HashMap k v -> v
findVariable k m = case HashMap.lookup k m of
                        Just v -> v
                        Nothing -> error $ "cannot find variable for " ++ show k

-- | at each timestamp, only one transition can be fired, we restrict the
-- fired transition id range here
sequentialTransitions :: Encoder ()
sequentialTransitions = do
    l <- loc <$> get
    lv <- abstractionLv <$> get
    lvRange <- lv2range <$> get
    let rng = findVariable lv lvRange
    mapM_ (fireAt rng) [0..(l-1)]
  where
    fireAt rng t = do
        tsMap <- time2variable <$> get
        lv <- abstractionLv <$> get
        let tsVar = findVariable (t, lv) tsMap
        tsZ3Var <- mkZ3IntVar tsVar
        start <- mkIntNum (fst rng)
        mkGe tsZ3Var start >>= assert
        end <- mkIntNum (snd rng)
        mkLt tsZ3Var end >>= assert

-- | if this place has no connected transition fired, 
-- it has the same # of tokens
noTransitionTokens :: Int -> Place -> Encoder ()
noTransitionTokens t p = noFirePlace t p
  where
    noFirePlace t p = do
        lv <- abstractionLv <$> get
        trans <- findVariable lv . transition2id <$> get
        let transitions = map (\i -> findVariable i trans)
                        $ Set.toList $ placePreset p `Set.union` placePostset p
        noFireLvs <- noFireAt transitions p t
        noFire <- mkOr noFireLvs >>= mkNot
        placeMap <- place2variable <$> get
        curr <- mkZ3IntVar $ findVariable (placeId p, t) placeMap
        next <- mkZ3IntVar $ findVariable (placeId p, t + 1) placeMap
        mkEq curr next >>= mkImplies noFire >>= assert

    noFireAt transitions p t = do
        idVars <- mapM mkIntNum transitions
        tsMap <- time2variable <$> get
        lv <- abstractionLv <$> get
        let tsVar = findVariable (t, lv) tsMap
        tsZ3Var <- mkZ3IntVar tsVar
        mapM (mkEq tsZ3Var) idVars

-- | calculate the preconditions for each transition to be fired
preconditionsTransitions :: Int -> Transition -> Encoder ()
preconditionsTransitions t tr = fireFor
  where
    -- get enough resources for current places to fire the tr
    getSatisfiedPlaces trVar f = do
        places <- pnPlaces . petriNet <$> get
        let p = case HashMap.lookup (flowPlace f) places of
                    Just pp -> pp
                    Nothing -> error $ "cannot find place " ++ (flowPlace f)
        w <- mkIntNum $ flowWeight f
        placeMap <- place2variable <$> get
        pVar <- mkZ3IntVar $ findVariable (placeId p,t) placeMap
        mkGe pVar w >>= mkImplies trVar >>= assert

    -- whether the src and dst places in the current tr is the same or "void"
    hasComplementary places p postFlow preFlow =   
        placeId p == "void" || 
       ((findVariable (flowPlace preFlow) places) == p && 
        flowWeight preFlow >= flowWeight postFlow)

    -- if the dest place has reached its maximum token, we cannot fire the tr
    hasReachedMax t tr trVar preFlows f = do
        places <- pnPlaces . petriNet <$> get
        let p = findVariable (flowPlace f) places
        w1 <- mkIntNum $ placeMaxToken p
        placeMap <- place2variable <$> get
        maxTokenVar <- mkZ3IntVar $ findVariable (placeId p, t) placeMap
        if foldr ((||) . (hasComplementary places p f)) False preFlows
            then return ()
            else mkEq maxTokenVar w1 >>= mkNot >>= mkImplies trVar >>= assert

    fireFor = do
        flows <- pnFlows . petriNet <$> get
        transMap <- transition2id <$> get
        tsMap <- time2variable <$> get
        lv <- abstractionLv <$> get
        let trId = findVariable (transitionId tr) (findVariable lv transMap)
        let tsVar = findVariable (t, lv) tsMap
        let preFlows = map (\f -> findVariable f flows)
                           (Set.toList $ transitionPreset tr)
        tsZ3Var <- mkZ3IntVar tsVar
        trVar <- mkIntNum trId >>= mkEq tsZ3Var
        mapM_ (getSatisfiedPlaces trVar) preFlows

postconditionsTransitions :: Int -> Transition -> Encoder ()
postconditionsTransitions t tr = placesToChange
  where
    addChangedPlace places pre f changeList = 
        let pid = flowPlace f
            p = findVariable pid places 
            w = if pre then -(flowWeight f) else flowWeight f
        in HashMap.insertWith (+) p w changeList

    mkChange t trVar p diff = do
        let d = if placeId p == "void" then 0 else diff
        placeMap <- place2variable <$> get
        before <- mkZ3IntVar $ findVariable (placeId p, t) placeMap
        after <- mkZ3IntVar $ findVariable (placeId p, t + 1) placeMap
        diffw <- mkIntNum d
        mkAdd [before, diffw] >>= mkEq after >>= mkImplies trVar >>= assert

    placesToChange = do
        flows <- pnFlows . petriNet <$> get
        places <- pnPlaces . petriNet <$> get
        let preFlows = map (\f -> findVariable f flows)
                           (Set.toList $ transitionPreset tr)
        let preChange = foldr (addChangedPlace places True) HashMap.empty preFlows
        let postFlows = map (\f -> findVariable f flows)
                            (Set.toList $ transitionPostset tr)
        let toChange = foldr (addChangedPlace places False) preChange postFlows
        transMap <- transition2id <$> get
        tsMap <- time2variable <$> get
        lv <- abstractionLv <$> get
        let trId = findVariable (transitionId tr) (findVariable lv transMap)
        let tsVar = findVariable (t, lv) tsMap
        tsZ3Var <- mkZ3IntVar tsVar
        trVar <- mkIntNum trId >>= mkEq tsZ3Var
        mapM_ (uncurry (mkChange t trVar)) (HashMap.toList toChange)

mustFireTransitions ::  Encoder ()
mustFireTransitions = do
    must <- mustFirers <$> get
    lv <- abstractionLv <$> get
    transitions <- findVariable lv . transition2id <$> get
    let mustTrans = HashMap.filterWithKey (\k _ -> nameInMust must k) transitions
    mapM_ fireTransition mustTrans
  where
    nameInMust must name = foldr ((||) . flip isInfixOf name) False must
    fireTransition tid = do
        l <- loc <$> get
        lv <- abstractionLv <$> get
        tsMap <- time2variable <$> get
        trId <- mkIntNum tid
        tsVars <- mapM (\t -> mkZ3IntVar (findVariable (t, lv) tsMap)) [0..(l-1)]
        trVars <- mapM (mkEq trId) tsVars
        mkOr trVars >>= assert
