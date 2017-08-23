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
import Control.Monad.State (StateT, evalStateT, get, put)
import Control.Monad.Except (Except, runExcept, throwError)
import Data.List (union, groupBy, intersect)
import Data.Foldable (foldrM)

import qualified Data.List ((\\))

data TypeError
  = UnknownVariable String
  | UnknownType String
  | ArityMismatch
  | InferenceFailure
  | TypeError Type Type
  | UnknownField Type String
  | GenericError String
  deriving (Show)

instance ErrorT TypeError where
  kind _ = "TypeError"

type Infer a = (StateT InferState (Except TypeError) a)

data InferState = InferState { uid :: Int }

typeCheck :: Type -> Type -> Infer ()
typeCheck actualTy expectedTy =
  when (not $ actualTy <: expectedTy) (throwError $ TypeError expectedTy actualTy)

data Ctx = Ctx { types :: [(Var, Type)]
               , values :: [(String, Type)]
               }

getType :: Var -> Ctx -> Infer Type
getType n ctx =
  case lookup n (types ctx) of
    Nothing -> throwError (UnknownType $ show n)
    Just t -> instantiate t

getValueType :: String -> Ctx -> Infer Type
getValueType n ctx =
  case lookup n (values ctx) of
    Nothing -> throwError (UnknownVariable n)
    Just t -> instantiate t

resolveId :: Ctx -> Id UnresolvedType -> Infer (Id Type)
resolveId ctx (n, ty) = (,) n  <$> resolveType ctx ty

resolveType :: Ctx -> UnresolvedType -> Infer Type
resolveType ctx (UnresolvedType (Var v)) =
  getType v ctx
resolveType ctx (UnresolvedType (Fun gen params ret)) = do
  params' <- mapM (resolveType ctx . UnresolvedType) params
  ret' <- resolveType ctx $ UnresolvedType ret
  return $ Fun gen params' ret'
resolveType ctx (UnresolvedType (Rec fieldsTy)) = do
  fieldsTy' <- mapM (\(n, t) -> resolveId ctx (n, UnresolvedType t)) fieldsTy
  return $ Rec fieldsTy'
resolveType ctx (UnresolvedType (TyApp t1 t2)) = do
  t1' <- resolveType ctx $ UnresolvedType t1
  t2' <- mapM (resolveType ctx . UnresolvedType) t2
  case t1' of
    TyAbs params ty ->
      let ctx' = foldl addType ctx (zip params t2')
       in resolveType ctx' (UnresolvedType ty)
    _ -> return $ TyApp t1' t2'

-- Trivial Types
resolveType _ (UnresolvedType Top) = return Top
resolveType _ (UnresolvedType Bot) = return Bot
resolveType _ (UnresolvedType Type) = return Type
resolveType _ (UnresolvedType (Con c)) = return (Con c)

-- Placeholder used by the parser - should never attempt to resolve
resolveType _ Placeholder = undefined

-- Only generated by the TypeChecker, can't be unresolved
resolveType _ (UnresolvedType (Cls _ _)) = undefined
resolveType _ (UnresolvedType (TyAbs _ _)) = undefined

instantiate :: Type -> Infer Type
instantiate (TyAbs gen ty) = do
  gen' <- mapM fresh gen
  let s = zip gen (map Var gen')
  return $ TyAbs gen' (subst s ty)
instantiate (Fun gen params ret) = do
  gen' <- mapM fresh gen
  let s = zip gen (map Var gen')
  return $ Fun gen' (map (subst s) params) (subst s ret)
instantiate ty = return ty

fresh :: Var -> Infer Var
fresh var = do
  s <- get
  put s{uid = uid s + 1}
  return $ unsafeFreshVar var (uid s)

addType :: Ctx -> (Var, Type) -> Ctx
addType ctx (n, ty) = ctx { types = (n, ty) : types ctx }

addValueType :: Ctx -> (String, Type) -> Ctx
addValueType ctx (n, ty) = ctx { values = (n, ty) : values ctx }

addGenerics :: [String] -> Ctx -> Ctx
addGenerics generics ctx =
  foldl (\ctx g -> addType ctx (var g, Var $ var g)) ctx generics

defaultCtx :: Ctx
defaultCtx =
  Ctx { types = [ (var "Int", int)
                , (var "Float", float)
                , (var "Char", char)
                , (var "String", string)
                , (var "Void", void)
                , (var "List", genericList)
                ]
      , values = [ ("int_print", [int] ~> void)
                 , ("int_add", [int, int] ~> int)
                 , ("int_sub", [int, int] ~> int)
                 , ("int_mul", [int, int] ~> int)
                 , ("True", bool)
                 , ("False", bool)
                 , ("Nil", genericList)
                 , ("Cons", Fun [var "T"] [Var $ var "T", list . Var $ var "T"] (list . Var $ var "T"))
                 ]
      }

initInfer :: InferState
initInfer = InferState { uid = 0 }

runInfer :: Infer a -> (a -> b) -> Result b
runInfer m f =
  case runExcept $ evalStateT m initInfer of
    Left err -> Left (Error err)
    Right v -> Right (f v)


infer :: Module Name UnresolvedType -> Result (Module (Id Type) Type, Type)
infer mod =
  runInfer
    (i_stmts defaultCtx (stmts mod))
    (\(stmts, ty) -> (Module stmts, ty))

inferStmt :: Ctx -> Stmt Name UnresolvedType -> Result (Ctx, Stmt (Id Type) Type, Type)
inferStmt ctx stmt =
  runInfer (i_stmt ctx stmt) id

i_stmts :: Ctx -> [Stmt Name UnresolvedType ] -> Infer ([Stmt (Id Type) Type], Type)
i_stmts ctx stmts = do
  (_, stmts', ty) <- foldM aux (ctx, [], void) stmts
  return (reverse stmts', ty)
    where
      aux :: (Ctx, [Stmt (Id Type) Type], Type) -> Stmt Name  UnresolvedType -> Infer (Ctx, [Stmt (Id Type) Type], Type)
      aux (ctx, stmts, _) stmt = do
        (ctx', stmt', ty) <- i_stmt ctx stmt
        return (ctx', stmt':stmts, ty)

i_stmt :: Ctx -> Stmt Name UnresolvedType -> Infer (Ctx, Stmt (Id Type) Type, Type)
i_stmt ctx (Expr expr) = do
  (expr', ty) <- i_expr ctx expr
  return (ctx, Expr expr', ty)
i_stmt ctx (FnStmt fn) = do
  (fn', ty) <- i_fn ctx fn
  return (addValueType ctx (name fn, ty), FnStmt fn', ty)
i_stmt ctx (Enum name generics ctors) = do
  let generics' = map var generics
  let mkEnumTy ty = case (ty, generics') of
                (Nothing, []) -> Con name
                (Nothing, _)  -> TyAbs generics' (TyApp (Con name) (map Var generics'))
                (Just t, [])  -> Fun [] t (Con name)
                (Just t, _)   -> Fun generics' t (TyApp (Con name) (map Var generics'))
  let enumTy = mkEnumTy Nothing
  let name' = (var name, enumTy)
  let ctx' = addGenerics generics ctx
  let ctx'' = addType ctx' name'
  (ctx''', ctors') <- foldrM (i_ctor mkEnumTy) (ctx'', []) ctors
  return (ctx''', (Enum (name, enumTy) generics ctors'), Type)
i_stmt ctx (Operator opGenerics opLhs opName opRhs opRetType opBody) = do
  let ctx' = addGenerics opGenerics ctx
  opLhs' <- resolveId ctx' opLhs
  opRhs' <- resolveId ctx' opRhs
  opRetType' <- resolveType ctx' opRetType
  let ctx'' = addValueType (addValueType ctx' opLhs') opRhs'
  (opBody', bodyTy) <- i_stmts ctx'' opBody
  typeCheck bodyTy opRetType'
  let ty = Fun (map var opGenerics) [snd opLhs', snd opRhs'] opRetType'
  let op' = Operator { opGenerics = opGenerics
                     , opLhs = opLhs'
                     , opName = (opName, ty)
                     , opRhs = opRhs'
                     , opRetType = opRetType'
                     , opBody = opBody' }
  return (addValueType ctx (opName, ty), op', ty)

i_stmt ctx (Let var expr) = do
  (expr', exprTy) <- i_expr ctx expr
  let ctx' = addValueType ctx (var, exprTy)
  let let' = Let (var, exprTy) expr'
  return (ctx', let', void)

i_stmt ctx (Class name vars methods) = do
  vars' <- mapM (resolveId ctx) vars
  let classTy = Cls name vars'
  let ctorTy = [Rec vars'] ~> classTy
  let ctx' = addType ctx (var name, classTy)
  let ctx'' = addValueType ctx' (name, ctorTy)

  (ctx''', methods') <- foldM (i_method classTy) (ctx'', []) methods
  let class' = Class (name, classTy) vars' methods'
  return (ctx''', class', Type)

i_method :: Type -> (Ctx, [Function (Id Type) Type]) -> Function Name UnresolvedType -> Infer (Ctx, [Function (Id Type) Type])
i_method classTy (ctx, fns) fn = do
  let ctx' = addType ctx (var "Self", classTy)
  let fn' = fn { params = ("self", UnresolvedType . Var $ var "Self") : params fn }
  (fn'', fnTy) <- i_fn ctx' fn'
  return (addValueType ctx (name fn, fnTy), fn'' : fns)

i_ctor :: (Maybe [Type] -> Type) -> DataCtor Name UnresolvedType -> (Ctx, [DataCtor (Id Type) Type]) -> Infer (Ctx, [DataCtor (Id Type) Type])
i_ctor mkEnumTy (name, types) (ctx, ctors) = do
  types' <- sequence (types >>= return . mapM (resolveType ctx))
  let ty = mkEnumTy types'
  return (addValueType ctx (name, ty), ((name, ty), types'):ctors)

i_fn :: Ctx -> Function Name UnresolvedType -> Infer (Function (Id Type) Type, Type)
i_fn ctx fn = do
  let ctx' = addGenerics (generics fn) ctx
  tyArgs <- mapM (resolveId ctx') (params fn)
  retType' <- resolveType ctx' (retType fn)
  let ty =
        Fun (map var $ generics fn)
            (if null tyArgs then [void] else map snd tyArgs)
            retType'
  let ctx'' = addValueType ctx' (name fn, ty)
  let ctx''' = foldl addValueType ctx'' tyArgs
  (body', bodyTy) <- i_stmts ctx''' (body fn)
  typeCheck bodyTy retType'
  let fn' = fn { name = (name fn, ty)
               , params = tyArgs
               , retType = retType'
               , body = body'
               }
  return (fn', ty)

i_expr :: Ctx -> Expr Name UnresolvedType -> Infer (Expr (Id Type) Type, Type)
i_expr _ (Literal lit) = return (Literal lit, i_lit lit)

i_expr ctx (Ident i) = do
  ty <- getValueType i ctx
  return (Ident (i, ty), ty)

i_expr _ VoidExpr = return (VoidExpr, void)

i_expr ctx (BinOp lhs op rhs) = do
  tyOp@(Fun _ _ retType) <- getValueType op ctx
  (lhs', lhsTy) <- i_expr ctx lhs
  (rhs', rhsTy) <- i_expr ctx rhs
  substs <- inferTyArgs [lhsTy, rhsTy] tyOp
  let tyOp' = subst substs tyOp
  return (BinOp lhs' (op, tyOp') rhs', subst substs retType)

i_expr ctx (Match expr cases) = do
  (expr', ty) <- i_expr ctx expr
  (cases', casesTy) <- unzip <$> mapM (i_case ctx ty) cases
  let retTy = case casesTy of
                [] -> void
                x:xs -> foldl (\/) x xs
  return (Match expr' cases', retTy)

i_expr ctx (Call fn types []) = i_expr ctx (Call fn types [VoidExpr])
i_expr ctx (Call fn types args) = do
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
  retType <- i_call ctx tyArgs [] tyFn'
  return (Call fn' (map snd substs) args', retType)

i_expr ctx (Record fields) = do
  (exprs, types) <- mapM (i_expr ctx . snd) fields >>= return . unzip
  let labels = map fst fields
  let fieldsTy = zip labels types
  let recordTy = Rec fieldsTy
  let record = Record (zip fieldsTy exprs)
  return (record, recordTy)

i_expr ctx (FieldAccess expr _ field) = do
  (expr', ty) <- i_expr ctx expr
  let
      aux :: [(String, Type)] -> Infer (Expr (Id Type) Type, Type)
      aux r = case lookup field r of
                Nothing -> throwError $ UnknownField (Rec r) field
                Just t -> return (FieldAccess expr' ty (field, t), t)
  case ty of
    Rec r -> aux r
    Cls _ r -> aux r
    _ -> throwError . GenericError $ "Expected a record, but found value of type " ++ show ty

i_expr ctx (If ifCond ifBody elseBody) = do
  (ifCond', ty) <- i_expr ctx ifCond
  typeCheck ty bool
  (ifBody', ifTy) <- i_stmts ctx ifBody
  (elseBody', elseTy) <- i_stmts ctx elseBody
  return (If ifCond' ifBody' elseBody', ifTy \/ elseTy)

i_expr ctx (List items) = do
  (items', itemsTy) <- unzip <$> mapM (i_expr ctx) items
  let ty = case itemsTy of
             [] -> genericList
             x:xs -> list $ foldl (\/) x xs
  return (List items', ty)

i_call :: Ctx -> [Type] -> [Type] -> Type -> Infer Type
i_call _ [] [] tyRet = return tyRet
i_call _ [] tyArgs tyRet = return $ Fun [] tyArgs tyRet
i_call ctx args [] tyRet =
  case tyRet of
    Fun [] tyArgs tyRet' -> i_call ctx args tyArgs tyRet'
    _ -> throwError ArityMismatch
i_call ctx (actualTy:args) (expectedTy:tyArgs) tyRet = do
  typeCheck actualTy expectedTy
  i_call ctx args tyArgs tyRet

i_lit :: Literal -> Type
i_lit (Integer _) = int
i_lit (Float _) = float
i_lit (Char _) = char
i_lit (String _) = string

i_case :: Ctx -> Type -> Case Name UnresolvedType -> Infer (Case (Id Type) Type, Type)
i_case ctx ty (Case pattern caseBody) = do
  (pattern', ctx') <- c_pattern ctx ty pattern
  (caseBody', ty) <- i_stmts ctx' caseBody
  return (Case pattern' caseBody', ty)

c_pattern :: Ctx -> Type -> Pattern Name -> Infer (Pattern (Id Type), Ctx)
c_pattern ctx _ PatDefault = return (PatDefault, ctx)
c_pattern ctx ty (PatLiteral l) = do
  let litTy = i_lit l
  typeCheck litTy ty
  return (PatLiteral l, ctx)
c_pattern ctx ty (PatVar v) =
  let pat = PatVar (v, ty)
      ctx' = addValueType ctx (v, ty)
   in return (pat, ctx')
c_pattern ctx ty (PatCtor name vars) = do
  ctorTy <- getValueType name ctx
  let (fnTy, params, retTy) = case ctorTy of
                            fn@(Fun [] params retTy) -> (fn, params, retTy)
                            fn@(Fun gen params retTy) -> (fn, params, TyAbs gen retTy)
                            t -> (Fun [] [] t, [], t)
  when (length vars /= length params) (throwError ArityMismatch)
  typeCheck retTy ty
  let substs = case (retTy, ty) of
                 (TyAbs gen _, TyApp _ args) -> zip gen args
                 _ -> []
  let params' = map (subst substs) params
  (vars', ctx') <- foldM aux ([], ctx) (zip params' vars)
  return (PatCtor (name, fnTy) vars', ctx')
    where
      aux (vars, ctx) (ty, var) = do
        (var', ctx') <- c_pattern ctx ty var
        return (var':vars, ctx')

-- Inference of type arguments for generic functions
inferTyArgs :: [Type] -> Type -> Infer [Substitution]
inferTyArgs tyArgs (Fun generics params retType) = do
  let initialCs = map (flip (Constraint Bot) Top) generics
  d <- zipWithM (constraintGen [] generics) tyArgs params
  let c = initialCs `meet` foldl meet [] d
  mapM (getSubst retType) c
inferTyArgs _ _ = throwError $ ArityMismatch

-- Variable Elimination

-- S ⇑V T
(//) :: [Var] -> Type -> Type

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

-- S ⇓V T
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

-- Constraint Solving
data Constraint
  = Constraint Type Var Type
  deriving (Eq, Show)

constraintGen :: [Var] -> [Var] -> Type -> Type -> Infer [Constraint]

-- CG-Top
constraintGen _ _ _ Top = return []

-- CG-Bot
constraintGen _ _ Bot _ = return []

-- CG-Upper
constraintGen v x (Var y) s | y `elem` x && fv s `intersect` x == [] =
  let t = v \\ s
   in return [Constraint Bot y t]

-- CG-Lower
constraintGen v x s (Var y) | y `elem` x && fv s `intersect` x == [] =
  let t = v // s
   in return [Constraint t y Top]

-- CG-Refl
constraintGen _v _x t1 t2 | t1 <: t2 = return []

-- CG-Fun
constraintGen v x (Fun y r s) (Fun y' t u)
  | y == y' && y `intersect` (v `union` x) == [] = do
    c <- zipWithM (constraintGen (v `union` y) x) t r
    d <- constraintGen (v `union` y) x s u
    return $ foldl meet [] c `meet` d

constraintGen v x (TyApp t11 t12) (TyApp t21 t22) = do
  cTy <- constraintGen v x t11 t21
  cArgs <- zipWithM (constraintGen v x) t12 t22
  return $ foldl meet [] cArgs `meet` cTy

constraintGen _v _x actual expected =
  throwError $ TypeError expected actual

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
      merge [] = undefined
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

variance :: Var -> Type -> Variance
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
variance v (Rec fields) =
  let vars = map (variance v . snd) fields
   in foldl joinVariance Bivariant vars
variance v (Cls _ vars) =
  let vars' = map (variance v . snd) vars
   in foldl joinVariance Bivariant vars'
variance v (TyAbs gen ty)
  | v `elem` gen = Bivariant
  | otherwise = variance v ty
variance v (TyApp ty args) =
  let vars = map (variance v) args
   in foldl joinVariance (variance v ty) vars

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
type Substitution = (Var, Type)

getSubst :: Type -> Constraint -> Infer Substitution
getSubst r (Constraint s x t) =
  case variance x r of
    Bivariant -> return (x, s)
    Covariant -> return (x, s)
    Contravariant -> return (x, t)
    Invariant | s == t -> return (x, s)
    _ -> throwError InferenceFailure
