module Typing.Subtyping
  ( (<:)
  , (\/)
  , (/\)
  , (//)
  , (\\)
  ) where

import Typing.Types
import Typing.Substitution

import Data.List (intersect, union)
import Data.Maybe (fromJust)

import qualified Data.List ((\\))

(<:) :: Type -> Type -> Bool

-- S-Refl
t <: u | t == u = True

-- S-Top
_ <: Top = True

-- S-Bot
Bot <: _ = True

-- S-Fun
(Fun v1 p1 t1) <: (Fun v2 p2 t2) =
  v1 == v2 && all (uncurry (<:)) (zip p2 p1) && t1 <: t2

_t1@(TyAbs gen t12) <: t2@(TyApp _t21 args) =
  let t1' = applySubst (zipSubst gen args) t12
   in t1' <: t2

(TyApp t11 t12) <: (TyApp t21 t22) =
  t11 <: t21 && and (zipWith (<:) t12 t22)

(Rec r1) <: (Rec r2) =
  all aux r2
    where
      aux (k, t2) = case lookup k r1 of
        Nothing -> False
        Just t1 -> t1 <: t2

_ <: _ = False

-- Least Upper Bound
(\/) :: Type -> Type -> Type

s \/ t | s <: t = t
s \/ t | t <: s = s
(Fun x v p) \/ (Fun x' w q) | x == x' =
  Fun x (zipWith (/\) v w) (p \/ q)
(Rec f1) \/ (Rec f2) =
  let fields = (fst <$> f1) `intersect` (fst <$> f2)
   in Rec $ map (\f -> (f, fromJust (lookup f f1) \/ fromJust (lookup f f2))) fields
_ \/ _ = Top

-- Greatest Lower Bound
(/\) :: Type -> Type -> Type
s /\ t | s <: t = s
s /\ t | t <: s = t
(Fun x v p) /\ (Fun x' w q) | x == x' =
  Fun x (zipWith (\/) v w) (p /\ q)
(Rec f1) /\ (Rec f2) =
  let fields = (fst <$> f1) `union` (fst <$> f2)
   in Rec $ map (\f -> (f, maybe Top id (lookup f f1) /\ maybe Top id (lookup f f2))) fields
_ /\ _ = Bot


-- VARIABLE ELIMITATION

-- Elimnate Up: S ⇑V T
(//) :: [Var] -> Type -> Type

-- VU-Top
_ // Top = Top

-- VU-Bot
_ // Bot = Bot

-- VU-Con
_ // (Con x) = (Con x)

-- VU-Type
_ // Type = Type

v // var@(Var x _)
  -- VU-Var-1
  | x `elem` v = Top
  -- VU-Var-2
  | otherwise = var

-- VU-Fun
v // (Fun x s t) =
  let u = map ((\\) v) s in
  let r = v // t in
  Fun x u r

v // (Rec fields) =
  let fields' = map (\(k, t) -> (k, v // t)) fields
   in Rec fields'

v // (Cls name vars) =
  let vars' = map (\(k, t) -> (k, v // t)) vars
   in Cls name vars'

v // (TyAbs gen ty) =
  let v' = v Data.List.\\ gen
   in TyAbs gen (v' // ty)

v // (TyApp ty args) =
  TyApp (v // ty) (map ((//) v) args)

-- Eliminate Down: S ⇓V T
(\\) :: [Var] -> Type -> Type
-- VD-Top
_ \\ Top = Top

-- VD-Bot
_ \\ Bot = Bot
--
-- VD-Con
_ \\ (Con x) = (Con x)

-- VD-Type
_ \\ Type = Type

v \\ var@(Var x _)
  -- VD-Var-1
  | x `elem` v = Bot
  -- VD-Var-2
  | otherwise = var

-- VD-Fun
v \\ (Fun x s t) =
  let u = map ((//) v) s in
  let r = v \\ t in
  Fun x u r

v \\ (Rec fields) =
  let fields' = map (\(k, t) -> (k, v \\ t)) fields
   in Rec fields'

v \\ (Cls name vars) =
  let vars' = map (\(k, t) -> (k, v \\ t)) vars
   in Cls name vars'

v \\ (TyAbs gen ty) =
  let v' = v Data.List.\\ gen
   in TyAbs gen (v' \\ ty)

v \\ (TyApp ty args) =
  TyApp (v \\ ty) (map ((\\) v) args)