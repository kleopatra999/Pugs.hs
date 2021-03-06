{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -fglasgow-exts #-}

module MO.Util (
    module MO.Util,
    module MO.Capture,
    module StringTable.Atom,
    trace
) where

import Data.Set (Set)
import qualified Data.Set as Set
import MO.Capture

import Data.Map (Map)
import StringTable.AtomMap as AtomMap hiding (map)
import Control.Monad (when)
import Debug.Trace (trace)
import Data.Typeable hiding (cast)
import GHC.Exts (unsafeCoerce#, Word(W#), Word#)
import StringTable.Atom
import qualified Data.Typeable as Typeable


-- Stole "on" combinator from ghc-6.7
-- http://haskell.org/ghc/dist/current/docs/libraries/base/Data-Function.html#v%3Aon
infixl 0 `on`
on :: (b -> b -> c) -> (a -> b) -> a -> a -> c
(*) `on` f = \x y -> f x * f y

traceShow :: Show a => a -> b -> b
traceShow = trace . show

traceM :: Monad m => String -> m ()
traceM x = trace x (return ())

-- Compare any two typeable things.
(?==?) :: (Eq a, Typeable a, Typeable b) => a -> b -> Bool
(?==?) x y = case Typeable.cast y of
    Just y' -> x == y'
    _       -> False

-- Order any two typeable things.
(?<=>?) :: (Ord a, Typeable a, Typeable b) => a -> b -> Ordering
(?<=>?) x y = case Typeable.cast y of
    Just y' -> x `compare` y'
    _       -> show (typeOf x) `compare` show (typeOf y)

{-# INLINE addressOf #-}
addressOf :: a -> Word
addressOf !x = W# (unsafeCoerce# x)

data Ord a => Collection a
    = MkCollection
    { c_objects :: Set a
    , c_names   :: AtomMap a
    }
    deriving (Eq, Ord, Typeable)


instance (Ord a, Show a) => Show (Collection a) where
    show (MkCollection _ n) = "<" ++ show n ++ ">"

cmap :: (Ord a, Ord b) => (a -> b) -> Collection a -> Collection b
cmap f MkCollection { c_names = bn } =
    let l = map (\(x,y) -> (x, f y)) (AtomMap.toList bn)
    in newCollection l
    

-- FIXME: This is not really safe since we could add same object with different
-- names. Must check how Set work and what MO's remove wanted.
remove :: (Monad m, Ord a) => Atom -> a -> Collection a -> m (Collection a)
remove name obj MkCollection{ c_objects = bo, c_names = bn } = do
    return $ MkCollection { c_objects = Set.delete obj bo
                          , c_names   = AtomMap.delete name bn
                          } 

add :: (Monad m, Ord a) => Atom -> a -> Collection a -> m (Collection a)
add name obj c@MkCollection{ c_objects = bo, c_names = bn } = do
    when (includes_name c name) $ fail "can't insert: name confict"
    return $ MkCollection { c_objects = Set.insert obj bo
                          , c_names   = AtomMap.insert name obj bn
                          }

insert :: (Ord a) => Atom -> a -> Collection a -> Collection a
insert name obj MkCollection{ c_objects = bo, c_names = bn } =
    MkCollection { c_objects = Set.insert obj bo
                 , c_names   = AtomMap.insert name obj bn
                 }

emptyCollection :: Ord a => Collection a
emptyCollection = newCollection []

-- FIXME: checks for repetition
newCollection :: Ord a => [(Atom, a)] -> Collection a
newCollection l = MkCollection { c_objects = os, c_names = ns }
    where os = Set.fromList (map snd l)
          ns = AtomMap.fromList l

newCollection' :: Ord a => (a -> Atom) -> [a] -> Collection a
newCollection' f l = newCollection pairs
    where pairs = map (\x -> (f x, x)) l

newCollectionMap :: Ord a => AtomMap a -> Collection a
newCollectionMap ns = MkCollection { c_objects = os, c_names = ns }
    where os = Set.fromList (AtomMap.elems ns)

items :: Ord a => Collection a -> [a]
items c = Set.elems (c_objects c)

items_named :: Ord a => Collection a -> [(Atom, a)]
items_named = AtomMap.toList . c_names

includes :: Ord a => Collection a -> a -> Bool
includes c obj = Set.member obj (c_objects c)

includes_name :: Ord a => Collection a -> Atom -> Bool
includes_name c name = AtomMap.member name (c_names c)

includes_any :: Ord a => Collection a -> [a] -> Bool
includes_any _ [] = False
includes_any c (x:xs) = (includes c x) || (includes_any c xs)

includes_any_name :: Ord a => Collection a -> [Atom] -> Bool
includes_any_name _ [] = False
includes_any_name c (x:xs) = (includes_name c x) || (includes_any_name c xs)

includes_all :: Ord a => Collection a -> [a] -> Bool
includes_all _ [] = False
includes_all c (x:xs) = (includes c x) && (includes_any c xs)

shadow :: Ord a => [Collection a] -> [a]
shadow = AtomMap.elems . shadow'

shadow' :: Ord a => [Collection a] -> AtomMap a
shadow' = AtomMap.unions . map c_names

shadow_collection :: Ord a => [Collection a] -> Collection a
shadow_collection = newCollectionMap . shadow'

merge :: Ord a => [Collection a] -> [a]
merge = AtomMap.elems . merge'

merge' :: Ord a => [Collection a] -> AtomMap a
merge' = foldl (AtomMap.unionWithKey (\k _ _ -> error ("merge conflict: " ++ show k))) AtomMap.empty . map c_names

merge_collection :: Ord a => [Collection a] -> Collection a
merge_collection = newCollectionMap . merge'

sym_shadowing :: (Show a, Ord a) => b -> (b -> [b]) -> (b -> Collection a) -> Collection a
sym_shadowing o parents f = shadow_collection [f o, all_parents]
    where all_parents = sym_merged_parents o parents f

sym_merged_parents :: (Show a, Ord a) => b -> (b -> [b]) -> (b -> Collection a) -> Collection a
sym_merged_parents o parents f = merge_collection cs
    where cs = map (\x -> sym_shadowing x parents f) (parents o)

sym_inheritance :: Ord a => b -> (b -> [b]) -> (b -> (Collection a)) -> Collection a
sym_inheritance o parents f = merge_collection (all_parents ++ [f o])
    where all_parents = map (\p -> sym_inheritance p parents f) (parents o)
