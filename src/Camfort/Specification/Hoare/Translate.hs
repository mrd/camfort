{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-unused-matches #-}

{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

-- TODO: Implement translation for more unsupported language parts

module Camfort.Specification.Hoare.Translate
  ( translateExpression
  , translateExpression'
  , module Types
  ) where

import           Prelude                                     hiding (span)

import           Data.Char                                   (toLower)
import           Data.Maybe                                  (fromMaybe, listToMaybe)
import           Data.Typeable
import           Text.Read                                   (readMaybe)

import           Control.Lens                                hiding (op, (.>))
import           Control.Monad.Except

import qualified Language.Fortran.AST                        as F

import           Language.Expression.Classes
import           Language.Expression.Constraints
import           Language.Expression.Dict
import           Language.Verification

import           Camfort.Specification.Hoare.Translate.Types as Types

--------------------------------------------------------------------------------
--  Translate
--------------------------------------------------------------------------------

translateExpression :: F.Expression ann -> MonadTranslate ann SomeExpr
translateExpression = \case
  e@(F.ExpValue ann span val) -> translateValue val
  e@(F.ExpBinary ann span bop e1 e2) -> translateBop e1 e2 bop
  e@(F.ExpUnary ann span uop operand) -> translateUop operand uop

  e@(F.ExpSubscript ann span lhs indices') -> errUnsupportedExpression e
  e@(F.ExpDataRef ann span e1 e2) -> errUnsupportedExpression e
  e@(F.ExpFunctionCall ann span fexpr args) -> errUnsupportedExpression e
  e@(F.ExpImpliedDo ann span es spec) -> errUnsupportedExpression e
  e@(F.ExpInitialisation ann span es) -> errUnsupportedExpression e
  e@(F.ExpReturnSpec ann span rval) -> errUnsupportedExpression e


translateValue :: F.Value ann -> MonadTranslate ann SomeExpr
translateValue = \case
  v@(F.ValInteger s) -> translateLiteral v (readMaybe :: String -> Maybe Integer) s

  v@(F.ValReal s) -> translateLiteral v (readMaybe :: String -> Maybe Double) s

  v@(F.ValComplex realPart complexPart) -> errUnsupportedValue v
  v@(F.ValString s) -> errUnsupportedValue v
  v@(F.ValHollerith s) -> errUnsupportedValue v

  v@(F.ValVariable nm) -> return $ Some $ var $ unknownVar nm

  v@(F.ValIntrinsic nm) -> errUnsupportedValue v

  v@(F.ValLogical s) ->
    let intoBool l = case map toLower l of
          ".true." -> Just True
          ".false." -> Just False
          _ -> Nothing
    in translateLiteral v intoBool s

  v@(F.ValOperator s) -> errUnsupportedValue v
  v@(F.ValAssignment) -> errUnsupportedValue v
  v@(F.ValType s) -> errUnsupportedValue v
  v@(F.ValStar) -> errUnsupportedValue v


translateLiteral :: (SymLit a) => F.Value ann -> (s -> Maybe a) -> s -> MonadTranslate ann SomeExpr
translateLiteral v readLit = fromMaybe (errBadLiteral v) . fmap (return . Some . lit) . readLit

translateBop :: F.Expression ann -> F.Expression ann -> F.BinaryOp -> MonadTranslate ann SomeExpr
translateBop e1 e2 op = case op of
  F.Addition       -> numericBop op (.+) e1 e2
  F.Subtraction    -> numericBop op (.-) e1 e2
  F.Multiplication -> numericBop op (.*) e1 e2

  F.LT  -> orderingBop op (.<) e1 e2
  F.LTE -> orderingBop op (.<=) e1 e2
  F.GT  -> orderingBop op (.>) e1 e2
  F.GTE -> orderingBop op (.>=) e1 e2

  F.EQ -> equalityBop op (.==) e1 e2
  F.NE -> equalityBop op (./=) e1 e2

  F.And -> booleanBop op (.&&) e1 e2
  F.Or  -> booleanBop op (.||) e1 e2

  _ -> errUnsupportedItem (LpBinaryOp op)

translateUop :: F.Expression ann -> F.UnaryOp -> MonadTranslate ann SomeExpr
translateUop e = \case
  F.Not -> do
    e' :: FortranExpr Bool <- translateExpression' e
    return (Some (enot e'))

  op@_ -> errUnsupportedItem (LpUnaryOp op)

--------------------------------------------------------------------------------
--  Operators
--------------------------------------------------------------------------------

numericBop
  :: F.BinaryOp
  -> (forall a. SymNum a => FortranExpr a -> FortranExpr a -> FortranExpr a)
  -> F.Expression ann -> F.Expression ann
  -> MonadTranslate ann SomeExpr
numericBop op f e1 e2 = do
  numInstances :: Dictmap SymNum <- view typemap

  Some e1' <- translateExpression e1

  fromMaybe (errInvalidOperatorApplication (LpBinaryOp op)) $
    withDictmap numInstances e1' $ do
      e2' <- translateExpression' e2
      return (Some (f e1' e2'))

booleanBop
  :: F.BinaryOp
  -> (forall a. SymBool a => FortranExpr a -> FortranExpr a -> FortranExpr a)
  -> F.Expression ann -> F.Expression ann
  -> MonadTranslate ann SomeExpr
booleanBop op f e1 e2 = do
  boolInstances :: Dictmap SymBool <- view typemap

  Some e1' <- translateExpression e1

  fromMaybe (errInvalidOperatorApplication (LpBinaryOp op)) $
    withDictmap boolInstances e1' $ do
      e2' <- translateExpression' e2
      return (Some (f e1' e2'))

equalityBop
  :: F.BinaryOp
  -> (forall b a. SymEq b a => FortranExpr a -> FortranExpr a -> FortranExpr b)
  -> F.Expression ann -> F.Expression ann
  -> MonadTranslate ann SomeExpr
equalityBop op f e1 e2 = do
  eqInstances :: Dictmap2 SymEq <- view typemap2
  Some e1' <- translateExpression e1

  fromMaybe (errInvalidOperatorApplication (LpBinaryOp op)) . listToMaybe $
    withDictmap2' eqInstances e1' $ \(_ :: Proxy b) -> do
      e2' <- translateExpression' e2
      return (Some (f e1' e2' :: FortranExpr b))

orderingBop
  :: F.BinaryOp
  -> (forall b a. SymOrd b a => FortranExpr a -> FortranExpr a -> FortranExpr b)
  -> F.Expression ann -> F.Expression ann
  -> MonadTranslate ann SomeExpr
orderingBop op f e1 e2 = do
  ordInstances :: Dictmap2 SymOrd <- view typemap2
  Some e1' <- translateExpression e1

  fromMaybe (errInvalidOperatorApplication (LpBinaryOp op)) . listToMaybe $
    withDictmap2' ordInstances e1' $ \(_ :: Proxy b) -> do
      e2' <- translateExpression' e2
      return (Some (f e1' e2' :: FortranExpr b))

--------------------------------------------------------------------------------
--  Translate at specific types
--------------------------------------------------------------------------------

translateExpression' :: (SymValue r) => F.Expression ann -> MonadTranslate ann (FortranExpr r)
translateExpression' = translateAtType LpExpression translateExpression

-- translateValue' :: (SymValue r) => F.Value ann -> MonadTranslate ann (FortranExpr r)
-- translateValue' = translateAtType LpValue translateValue

-- translateLiteral' :: (SymLit a, SymValue r) => F.Value ann -> (s -> Maybe a) -> s -> MonadTranslate ann (FortranExpr r)
-- translateLiteral' v readLit = translateAtType (const (LpValue v)) (translateLiteral v readLit)

--------------------------------------------------------------------------------
--  Combinators
--------------------------------------------------------------------------------

unknownVar :: l -> Var l Unknown
unknownVar = Var

--------------------------------------------------------------------------------
--  Dynamically typed expressions
--------------------------------------------------------------------------------

-- TODO: Check if the types are actually coercible in Fortran.
tryCoerce :: (SymValue a, SymValue b) => FortranExpr a -> Maybe (FortranExpr b)
tryCoerce e = Just (ecoerce e)

-- | Given a dynamically typed expression, extract the underlying typed
-- expression. If it is already the desired type, return it as is. Otherwise,
-- try to coerce it to the desired type. Returns the 'TypeRep' of the
-- expression's real type, if the value is the wrong type and cannot be coerced
-- into the correct type.
extractOrCoerceExpr :: forall a. (SymValue a) => SomeExpr -> Either TypeRep (FortranExpr a)
extractOrCoerceExpr (Some (e :: FortranExpr b))
  | Just Refl <- eqT :: Maybe (a :~: b) = Right e
  | Just x <- tryCoerce e = Right x
  | otherwise = Left (typeRep (Proxy :: Proxy b))

translateAtType
  :: (SymValue r)
  => (a -> LangPart ann)
  -> (a -> MonadTranslate ann SomeExpr)
  -> a -> MonadTranslate ann (FortranExpr r)
translateAtType toLp translate x =
  do someY <- translate x
     case extractOrCoerceExpr someY of
       Right y -> return y
       Left ty -> errUnexpectedType (toLp x) ty
