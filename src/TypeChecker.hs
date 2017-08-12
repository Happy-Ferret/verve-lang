module TypeChecker
  ( infer
  , inferStmt
  , Ctx
  , defaultCtx
  , TypeError
  ) where

import Absyn
import Error
import Types

import Control.Monad (foldM, when, zipWithM)
import Data.List (union, groupBy, intersect)
import Data.Foldable (foldrM)
import Debug.Trace

data TypeError
  = UnknownVariable String
  | ArityMismatch
  | InferenceFailure
  | TypeError Type Type
  deriving (Show)

instance ErrorT TypeError where
  kind _ = "TypeError"

typeCheck :: Type -> Type -> Result ()
typeCheck actualTy expectedTy =
  when (actualTy /= expectedTy) (mkError $ TypeError expectedTy actualTy)

data Ctx = Ctx [(String, Type)]

getType :: String -> Ctx -> Maybe Type
getType n (Ctx ctx) = lookup n ctx

getType' :: String -> Ctx -> Result Type
getType' n ctx =
  case getType n ctx of
    Nothing -> mkError (UnknownVariable n)
    Just t -> return t

resolveId :: Ctx -> Id UnresolvedType -> Result (Id Type)
resolveId ctx (n, ty) = (,) n  <$> resolveType ctx ty

resolveType :: Ctx -> UnresolvedType -> Result Type
resolveType ctx (UnresolvedType (Con n)) =
  getType' n ctx
resolveType ctx (UnresolvedType (Fun gen params ret)) = do
  params' <- mapM (resolveType ctx . UnresolvedType) params
  ret' <- resolveType ctx $ UnresolvedType ret
  return $ Fun gen params' ret'
resolveType _ (UnresolvedType t) = return t

addType :: Ctx -> (String, Type) -> Ctx
addType (Ctx ctx) (n, ty) = Ctx ((n, ty) : ctx)

addGenerics :: [String] -> Ctx -> Ctx
addGenerics generics ctx =
  foldl (\ctx g -> addType ctx (g, Var g)) ctx generics

defaultCtx :: Ctx
defaultCtx =
  Ctx [ ("Int", int)
      , ("Float", float)
      , ("Char", char)
      , ("String", string)
      , ("Void", void)
      , ("int_print", Fun [] [int] void)
      , ("int_add", Fun [] [int, int] int)
      ]

infer :: Module Name UnresolvedType -> Result (Module (Id Type) Type, Type)
infer mod = do
  (stmts, ty) <- i_stmts defaultCtx (stmts mod)
  return (Module stmts, ty)

inferStmt :: Ctx -> Stmt Name UnresolvedType -> Result (Ctx, Stmt (Id Type) Type, Type)
inferStmt = i_stmt

i_stmts :: Ctx -> [Stmt Name UnresolvedType ] -> Result ([Stmt (Id Type) Type], Type)
i_stmts ctx stmts = do
  (_, stmts', ty) <- foldM aux (ctx, [], void) stmts
  return (reverse stmts', ty)
    where
      aux :: (Ctx, [Stmt (Id Type) Type], Type) -> Stmt Name  UnresolvedType -> Result (Ctx, [Stmt (Id Type) Type], Type)
      aux (ctx, stmts, _) stmt = do
        (ctx', stmt', ty) <- i_stmt ctx stmt
        return (ctx', stmt':stmts, ty)

i_stmt :: Ctx -> Stmt Name UnresolvedType -> Result (Ctx, Stmt (Id Type) Type, Type)
i_stmt ctx (Expr expr) = do
  (expr', ty) <- i_expr ctx expr
  return (ctx, Expr expr', ty)
i_stmt ctx (FnStmt fn) = do
  (fn', ty) <- i_fn ctx fn
  return (addType ctx (name fn, ty), FnStmt fn', ty)
i_stmt ctx (Enum name ctors) = do
  let name' = (name, Type)
  (ctx', ctors') <- foldrM (i_ctor name) (ctx, []) ctors
  return (addType ctx' (name, Type), (Enum name' ctors'), Type)
i_stmt ctx op@(Operator opGenerics opLhs opName opRhs opRetType opBody) = do
  let ctx' = addGenerics opGenerics ctx
  opLhs' <- resolveId ctx' opLhs
  opRhs' <- resolveId ctx' opRhs
  opRetType' <- resolveType ctx' opRetType
  let ctx'' = addType (addType ctx' opLhs') opRhs'
  (opBody', bodyTy) <- i_stmts ctx'' opBody
  typeCheck bodyTy opRetType'
  let ty = Fun opGenerics [snd opLhs', snd opRhs'] opRetType'
  let op' = op { opLhs = opLhs'
               , opName = (opName, ty)
               , opRhs = opRhs'
               , opRetType = opRetType'
               , opBody = opBody' }
  return (addType ctx (opName, ty), op', ty)

i_ctor :: Name -> DataCtor Name UnresolvedType -> (Ctx, [DataCtor (Id Type) Type]) -> Result (Ctx, [DataCtor (Id Type) Type])
i_ctor enum (name, types) (ctx, ctors) = do
  let enumTy = Con enum
  (types', ty) <- case types of
          Nothing -> return (Nothing, enumTy)
          Just t -> do
            types' <- mapM (resolveType ctx) t
            return (Just types', Fun [] types' enumTy)
  return (addType ctx (name, ty), ((name, ty), types'):ctors)

i_fn :: Ctx -> Function Name UnresolvedType -> Result (Function (Id Type) Type, Type)
i_fn ctx fn = do
  let ctx' = addGenerics (generics fn) ctx
  tyArgs <- mapM (resolveId ctx') (params fn)
  retType' <- resolveType ctx' (retType fn)
  let ty =
        Fun (generics fn)
            (if null tyArgs then [void] else map snd tyArgs)
            retType'
  let ctx'' = foldl addType ctx' tyArgs
  (body', bodyTy) <- i_stmts ctx'' (body fn)
  typeCheck bodyTy retType'
  let fn' = fn { name = (name fn, ty)
               , params = tyArgs
               , retType = retType'
               , body = body'
               }
  return (fn', ty)

i_expr :: Ctx -> Expr Name UnresolvedType -> Result (Expr (Id Type) Type, Type)
i_expr _ (Literal lit) = return (Literal lit, i_lit lit)

i_expr ctx (Ident i) =
  case getType i ctx of
    Nothing -> mkError $ UnknownVariable i
    Just ty -> return (Ident (i, ty), ty)

i_expr ctx VoidExpr = return (VoidExpr, void)

i_expr ctx (BinOp lhs op rhs) = do
  tyOp@(Fun _ _ retType) <- getType' op ctx
  (lhs', lhsTy) <- i_expr ctx lhs
  (rhs', rhsTy) <- i_expr ctx rhs
  substs <- inferTyArgs [lhsTy, rhsTy] tyOp
  let tyOp' = subst substs tyOp
  return (BinOp lhs' (op, tyOp') rhs', subst substs retType)

i_expr ctx (Match expr cases) = do
  (expr', ty) <- i_expr ctx expr
  (cases', casesTy) <- unzip <$> mapM (i_case ctx ty) cases
  retTy <- case casesTy of
    [] -> return void
    x:xs -> mapM_ (typeCheck x) xs >> return x
  return (Match expr' cases', retTy)

i_expr ctx (App fn types []) = i_expr ctx (App fn types [VoidExpr])
i_expr ctx (App fn types args) = do
  -- TODO: handle the case where tyFn is not a fun (TypeError)
  (fn', tyFn@(Fun generics t1 t2)) <- i_expr ctx fn
  (args', tyArgs) <- mapM (i_expr ctx) args >>= return . unzip
  types' <- mapM (resolveType ctx) types
  substs <-
        case (tyFn, types') of
          (Fun (_:_) _ _, []) ->
            inferTyArgs tyArgs tyFn
          _ ->
            return $ zip generics types'
  let tyFn' = subst substs (Fun [] t1 t2)
  retType <- i_app ctx tyArgs [] tyFn'
  return (App fn' (map snd substs) args', retType)

i_app :: Ctx -> [Type] -> [Type] -> Type -> Result Type
i_app _ [] [] tyRet = return tyRet
i_app _ [] tyArgs tyRet = return $ Fun [] tyArgs tyRet
i_app ctx args [] tyRet =
  case tyRet of
    Fun [] tyArgs tyRet' -> i_app ctx args tyArgs tyRet'
    _ -> mkError ArityMismatch
i_app ctx (actualTy:args) (expectedTy:tyArgs) tyRet = do
  typeCheck actualTy expectedTy
  i_app ctx args tyArgs tyRet

i_lit :: Literal -> Type
i_lit (Integer _) = int
i_lit (Float _) = float
i_lit (Char _) = char
i_lit (String _) = string

i_case :: Ctx -> Type -> Case Name UnresolvedType -> Result (Case (Id Type) Type, Type)
i_case ctx ty (Case pattern caseBody) = do
  (pattern', ctx') <- c_pattern ctx ty pattern
  (caseBody', ty) <- i_expr ctx' caseBody
  return (Case pattern' caseBody', ty)

c_pattern :: Ctx -> Type -> Pattern Name -> Result (Pattern (Id Type), Ctx)
c_pattern ctx _ PatDefault = return (PatDefault, ctx)
c_pattern ctx ty (PatLiteral l) = do
  let litTy = i_lit l
  typeCheck ty litTy
  return (PatLiteral l, ctx)
c_pattern ctx ty (PatVar v) =
  let pat = PatVar (v, ty)
      ctx' = addType ctx (v, ty)
   in return (pat, ctx')
c_pattern ctx ty (PatCtor name vars) = do
  ctorTy <- getType' name ctx
  let fnTy@(Fun _ params retTy) = case ctorTy of
            fn@(Fun _ _ _) -> fn
            t -> Fun [] [] t
  when (length vars /= length params) (mkError ArityMismatch)
  typeCheck ty retTy
  (vars', ctx') <- foldM aux ([], ctx) (zip params vars)
  return (PatCtor (name, fnTy) vars', ctx')
    where
      aux (vars, ctx) (ty, var) = do
        (var', ctx') <- c_pattern ctx ty var
        return (var':vars, ctx')

-- Inference of type arguments for generic functions
inferTyArgs :: [Type] -> Type -> Result [Substitution]
inferTyArgs tyArgs (Fun generics params retType) = do
  d <- zipWithM (constraintGen [] generics) tyArgs params
  let c = foldl meet [] d
  mapM (getSubst retType) c
inferTyArgs _ _ = mkError $ ArityMismatch

-- Variable Elimination

-- S ⇑V T
(//) :: [String] -> Type -> Type

-- VU-Top
_ // Top = Top

-- VU-Bot
_ // Bot = Bot

-- VU-Con
_ // (Con x) = (Con x)

-- VU-Type
_ // Type = Type

v // (Var x)
  -- VU-Var-1
  | x `elem` v = Top
  -- VU-Var-2
  | otherwise = (Var x)

-- VU-Fun
v // (Fun x s t) =
  let u = map ((\\) v) s in
  let r = v // t in
  Fun x u r

-- S ⇓V T
(\\) :: [String] -> Type -> Type
-- VD-Top
_ \\ Top = Top

-- VD-Bot
_ \\ Bot = Bot
--
-- VD-Con
_ \\ (Con x) = (Con x)

-- VD-Type
_ \\ Type = Type

v \\ (Var x)
  -- VD-Var-1
  | x `elem` v = Bot
  -- VD-Var-2
  | otherwise = Var x

-- VD-Fun
v \\ (Fun x s t) =
  let u = map ((//) v) s in
  let r = v \\ t in
  Fun x u r

-- Constraint Solving
data Constraint
  = Constraint Type String Type
  deriving (Eq, Show)

constraintGen :: [String] -> [String] -> Type -> Type -> Result [Constraint]

-- CG-Top
constraintGen _ _ _ Top = return []

-- CG-Bot
constraintGen _ _ Bot _ = return []

-- CG-Upper
constraintGen v x (Var y) s | y `elem` x && fv s `intersect` x == [] =
  let t = v \\ s in
  return [Constraint Bot y t]

-- CG-Lower
constraintGen v x s (Var y) | y `elem` x && fv s `intersect` x == [] =
  let t = v // s in
  return [Constraint t y Top]

-- CG-Refl
constraintGen v x Type Type = return []
constraintGen v x (Con y) (Con y') | y == y' = return []
constraintGen v x (Var y) (Var y') | y == y' && y `notElem` x =
  return []

-- CG-Fun
constraintGen v x (Fun y r s) (Fun y' t u)
  | y == y' && y `intersect` (v `union` x) == [] = do
    c <- zipWithM (constraintGen (v `union` y) x) t r
    d <- constraintGen (v `union` y) x s u
    return $ foldl meet [] c `meet` d

constraintGen v x s t =
  mkError $ TypeError s t

-- Least Upper Bound
(\/) :: Type -> Type -> Type

s \/ t | s <: t = t
s \/ t | t <: s = s
(Fun x v p) \/ (Fun x' w q) | x == x' =
  Fun x (zipWith (/\) v w) (p \/ q)
_ \/ _ = Top

-- Greatest Lower Bound
(/\) :: Type -> Type -> Type
s /\ t | s <: t = s
s /\ t | t <: s = t
(Fun x v p) /\ (Fun x' w q) | x == x' =
  Fun x (zipWith (\/) v w) (p /\ q)
_ /\ _ = Bot

-- The meet of two X/V-constraints C and D, written C /\ D, is defined as follows:
meet :: [Constraint] -> [Constraint] -> [Constraint]
meet c [] = c
meet [] d = d
meet c d =
  map merge cs
    where
      cs = groupBy prj (c `union` d)
      prj (Constraint _ t _) (Constraint _ u _) = t == u
      merge (c:cs) = foldl mergeC c cs
      mergeC (Constraint s x t) (Constraint u _ v) =
        Constraint (s \/ u) x (t /\ v)

--- Calculate Variance
data Variance
  = Bivariant
  | Covariant
  | Contravariant
  | Invariant
  deriving (Eq, Show)

variance :: String -> Type -> Variance
variance _ Top = Bivariant
variance _ Bot = Bivariant
variance _ (Con _) = Bivariant
variance _ Type = Bivariant
variance v (Var x)
  | v == x = Covariant
  | otherwise = Bivariant
variance v (Fun x t r)
  | v `elem` x = Bivariant
  | otherwise =
    let t' = map (invertVariance . variance v) t in
    (foldl joinVariance Bivariant t') `joinVariance` variance v r

invertVariance :: Variance -> Variance
invertVariance Covariant = Contravariant
invertVariance Contravariant = Covariant
invertVariance c = c

joinVariance :: Variance -> Variance -> Variance
joinVariance Bivariant d = d
joinVariance c Bivariant = c
joinVariance c d | c == d = c
joinVariance _ _ = Invariant

-- Create Substitution
type Substitution = (String, Type)

getSubst :: Type -> Constraint -> Result Substitution
getSubst r (Constraint s x t) =
  let m = (variance x r) in
  case m of
    Bivariant -> return (x, s)
    Covariant -> return (x, s)
    Contravariant -> return (x, t)
    Invariant | s == t -> return (x, s)
    _ -> mkError InferenceFailure
