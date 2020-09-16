{-# LANGUAGE FlexibleInstances, FlexibleContexts, MultiParamTypeClasses, TypeFamilies, DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
module InternalTypeGen where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad.Logic (liftM)
import Data.Char (ord)
import Data.Containers.ListUtils (nubOrd)
import Data.Data (Data(..))
import Data.List (isInfixOf, elemIndex, nub, drop, reverse, intersect)
import Data.Typeable (typeOf, Typeable)
import System.IO.Silently (silence)
import Text.Printf (printf)

import qualified Hoogle as Hoogle
import qualified Test.ChasingBottoms as CB
import qualified Test.LeanCheck.Core as SF
import qualified Test.LeanCheck.Function.ShowFunction as SF
import qualified Test.QuickCheck as QC
import qualified Test.SmallCheck.Series as SS

defaultShowFunctionDepth  = 2           :: Int
defaultMaxOutputLength    = 200         :: CB.Nat
defaultSeriesLimit        = 5           :: Int
defaultTimeoutMicro       = 400         :: Int
defaultIntRange           = [-2..10]    :: [Int]
defaultCharRange          = ['a'..'d']  :: [Char]
defaultFuncSpecialSize    = 4           :: Int
defaultTestArgs           = QC.stdArgs {QC.chatty = False, QC.maxDiscardRatio = 1, QC.maxSuccess = 100, QC.maxSize = 7} :: QC.Args

instance Eq a => Eq (CB.Result a) where
  (CB.Value a) == (CB.Value b) = a == b
  CB.NonTermination == CB.NonTermination = True
  (CB.Exception _) == (CB.Exception _) = True
  _ == _ = False

instance Ord a => Ord (CB.Result a) where
  (CB.Value a) `compare` (CB.Value b) = a `compare` b
  (CB.Value _) `compare` _ = GT
  (CB.Exception _) `compare` (CB.Exception _) = EQ
  (CB.Exception _) `compare` (CB.Value _) = LT
  (CB.Exception _) `compare` _ = GT
  (CB.NonTermination) `compare` (CB.NonTermination) = EQ
  (CB.NonTermination) `compare` _ = LT

isFailedResult :: CB.Result String -> Bool
isFailedResult result = case result of
  CB.NonTermination -> True
  CB.Exception _ -> True
  CB.Value a | "_|_" `isInfixOf` a -> True
  CB.Value a | "Exception" `isInfixOf` a -> True
  _ -> False

showCBResult :: CB.Result String -> String
showCBResult = \case
                  CB.Value a | "_|_" `isInfixOf` a -> "bottom"
                  CB.Value a -> a
                  CB.NonTermination -> "diverge"
                  CB.Exception ex -> show ex

anyDuplicate :: Ord a => [a] -> Bool
anyDuplicate [x, y] = x == y
anyDuplicate xs = length (nubOrd xs) /= length xs

labelEvaluation :: (Data a, QC.Testable prop) => [String] -> [a] -> ([CB.Result String] -> prop) -> IO QC.Property
labelEvaluation inputs values prop = do
    outputs <- mapM (evaluateValue defaultTimeoutMicro) values
    
    let examples = map (Example inputs . showCBResult) outputs
    return $ QC.label (show examples) (prop outputs)
  where
    evaluateValue :: Data a => Int -> a -> IO (CB.Result String)
    evaluateValue timeInMicro = (CB.timeOutMicro timeInMicro . evaluate . force . CB.approxShow defaultMaxOutputLength)

-- * instance defined in `Types.IOFormat`
data Example = Example {
    inputs :: [String],
    output :: String
} deriving(Eq, Show, Read)

-- * Custom Datatype for Range Restriction
newtype  MyInt = MyIntValue Int deriving (Eq, Data)
instance Ord              MyInt where compare (MyIntValue l) (MyIntValue r) = compare l r      
instance Show             MyInt where show (MyIntValue v) = show v
instance SF.Listable      MyInt where list = map MyIntValue defaultIntRange
instance SF.ShowFunction  MyInt where bindtiers (MyIntValue v) = SF.bindtiers v
instance QC.Arbitrary     MyInt where arbitrary = QC.elements (map MyIntValue defaultIntRange)
instance QC.CoArbitrary   MyInt where coarbitrary (MyIntValue v) = QC.coarbitraryIntegral v

newtype  MyChar = MyCharValue Char deriving (Eq, Data)
instance Ord              MyChar where compare (MyCharValue l) (MyCharValue r) = compare l r
instance Show             MyChar where show (MyCharValue v) = show v
instance SF.Listable      MyChar where list = map MyCharValue defaultCharRange
instance SF.ShowFunction  MyChar where bindtiers (MyCharValue v) = SF.bindtiers v
instance QC.Arbitrary     MyChar where arbitrary = QC.elements (map MyCharValue defaultCharRange)
instance QC.CoArbitrary   MyChar where coarbitrary (MyCharValue v) = QC.coarbitrary $ ord v

data     MyFun a b = Generated (a -> b) | Expression String (a -> b)
instance (QC.Arbitrary a, QC.CoArbitrary b)                       => QC.CoArbitrary (MyFun a b)   where coarbitrary = \case Generated f -> QC.coarbitrary f; Expression _ f -> QC.coarbitrary f
instance (Show a, SF.Listable a, SF.ShowFunction b)               => Show (MyFun a b)             where show = \case Expression str _ -> str; Generated f -> "(" ++ SF.showFunctionLine defaultShowFunctionDepth f ++ ")"
instance (Show a, SF.Listable a, SF.ShowFunction b)               => SF.ShowFunction (MyFun a b)  where bindtiers = \case Generated f -> SF.bindtiers f; Expression _ f -> SF.bindtiers f
instance {-# OVERLAPPABLE #-} (QC.CoArbitrary a, QC.Arbitrary b)  => QC.Arbitrary (MyFun a b)     where arbitrary = liftM Generated QC.arbitrary
        
-- * Custom Datatype Conversion
class    Unwrappable a b                                                            where unwrap :: a -> b; wrap :: b -> a
instance Unwrappable MyInt Int                                                      where unwrap (MyIntValue v) = v; wrap = MyIntValue
instance Unwrappable MyChar Char                                                    where unwrap (MyCharValue v) = v; wrap = MyCharValue
instance (Unwrappable a c, Unwrappable b d)   => Unwrappable (MyFun a b) (c -> d)   where 
  unwrap = \case Generated f -> \x -> unwrap $ f $ wrap x; Expression _ f -> \x -> unwrap $ f $ wrap x
  wrap f = Generated $ \x -> wrap $ f $ unwrap x

instance {-# OVERLAPPABLE #-} (a ~ b)         => Unwrappable a b                    where unwrap = id; wrap = id
instance {-# OVERLAPPING #-} Unwrappable a b  => Unwrappable [a] [b]                where unwrap = fmap unwrap; wrap = fmap wrap
instance {-# OVERLAPPING #-} Unwrappable a b  => Unwrappable (Maybe a) (Maybe b)    where unwrap = fmap unwrap; wrap = fmap wrap
instance (Unwrappable a c, Unwrappable b d)   => Unwrappable (a, b) (c, d)          where unwrap (x, y) = (unwrap x, unwrap y); wrap (x, y) = (wrap x, wrap y)

instance (Unwrappable a c, Unwrappable b d)   => Unwrappable (Either a b) (Either c d) where
  wrap    = \case Left v -> Left $ wrap v;    Right v -> Right $ wrap v
  unwrap  = \case Left v -> Left $ unwrap v;  Right v -> Right $ unwrap v