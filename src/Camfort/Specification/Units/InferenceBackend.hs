{-
   Copyright 2016, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}

{-
  Units of measure extension to Fortran: backend
-}

{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Camfort.Specification.Units.InferenceBackend
  ( inconsistentConstraints, criticalVariables, inferVariables
  -- mainly for debugging and testing:
  , shiftTerms, flattenConstraints, flattenUnits, constraintsToMatrix, constraintsToMatrices
  , rref, isInconsistentRREF, genUnitAssignments )
where

import Data.Tuple (swap)
import Data.Maybe (maybeToList)
import Data.List ((\\), findIndex, partition, sortBy, group, tails)
import Data.Generics.Uniplate.Operations (rewrite)
import Control.Monad
import Control.Monad.ST
import Control.Arrow (first, second)
import qualified Data.Map.Strict as M
import qualified Data.Array as A

import Camfort.Specification.Units.Environment

import Numeric.LinearAlgebra (
    atIndex, (<>), rank, (?), rows, cols,
    takeColumns, dropRows, subMatrix, diag, fromBlocks,
    ident,
  )
import qualified Numeric.LinearAlgebra as H
import Numeric.LinearAlgebra.Devel (
    newMatrix, readMatrix, writeMatrix, runSTMatrix, freezeMatrix, STMatrix
  )


--------------------------------------------------

-- | Returns just the list of constraints that were identified as
-- being possible candidates for inconsistency, if there is a problem.
inconsistentConstraints :: Constraints -> Maybe Constraints
inconsistentConstraints [] = Nothing
inconsistentConstraints cons
  | null inconsists = Nothing
  | otherwise       = Just [ con | (con, i) <- zip cons [0..], i `elem` inconsists ]
  where
    (_, _, inconsists, _, _) = constraintsToMatrices cons

--------------------------------------------------

-- | Identifies the variables that need to be annotated in order for
-- inference or checking to work.
criticalVariables :: Constraints -> [UnitInfo]
criticalVariables [] = []
criticalVariables cons = filter (not . isUnitRHS) $ map (colA A.!) criticalIndices
  where
    (unsolvedM, _, colA) = constraintsToMatrix cons
    solvedM                       = rref unsolvedM
    uncriticalIndices             = concatMap (maybeToList . findIndex (/= 0)) $ H.toLists solvedM
    criticalIndices               = A.indices colA \\ uncriticalIndices
    isUnitRHS (UnitName _)       = True; isUnitRHS _ = False

--------------------------------------------------

-- | Returns list of formerly-undetermined variables and their units.
inferVariables :: Constraints -> [(VV, UnitInfo)]
inferVariables cons = unitVarAssignments
  where
    unitAssignments = genUnitAssignments cons
    -- Find the rows corresponding to the distilled "unit :: var"
    -- information for ordinary (non-polymorphic) variables.
    unitVarAssignments            =
      [ (var, units) | ([UnitPow (UnitVar var)                 k], units) <- unitAssignments, k `approxEq` 1 ] ++
      [ (var, units) | ([UnitPow (UnitParamVarAbs (_, var)) k], units)    <- unitAssignments, k `approxEq` 1 ]

-- | Raw units-assignment pairs.
genUnitAssignments :: [Constraint] -> [([UnitInfo], UnitInfo)]
genUnitAssignments [] = []
genUnitAssignments cons
  | null cols       = []
  | null inconsists = unitAssignments
  | otherwise       = []
  where
    (unsolvedM, inconsists, colA) = constraintsToMatrix cons
    solvedM                       = rref unsolvedM
    cols                          = A.elems colA

    -- Convert the rows of the solved matrix into flattened unit
    -- expressions in the form of "unit ** k".
    unitPows                      = map (concatMap flattenUnits . zipWith UnitPow cols) (H.toLists solvedM)

    -- Variables to the left, unit names to the right side of the equation.
    unitAssignments               = map (fmap (foldUnits . map negatePosAbs) . partition (not . isUnitRHS)) unitPows
    isUnitRHS (UnitPow (UnitName _) _)        = True
    isUnitRHS (UnitPow (UnitParamEAPAbs _) _) = True
    -- Because this version of isUnitRHS different from
    -- constraintsToMatrix interpretation, we need to ensure that any
    -- moved ParamPosAbs units are negated, because they are
    -- effectively being shifted across the equal-sign:
    isUnitRHS (UnitPow (UnitParamPosAbs _) _) = True
    isUnitRHS _                               = False

    foldUnits units
      | null units = UnitlessVar
      | otherwise  = foldl1 UnitMul units

--------------------------------------------------

simplifyUnits :: UnitInfo -> UnitInfo
simplifyUnits = rewrite rw
  where
    rw (UnitMul (UnitMul u1 u2) u3)                          = Just $ UnitMul u1 (UnitMul u2 u3)
    rw (UnitMul u1 u2) | u1 == u2                            = Just $ UnitPow u1 2
    rw (UnitPow (UnitPow u1 p1) p2)                          = Just $ UnitPow u1 (p1 * p2)
    rw (UnitMul (UnitPow u1 p1) (UnitPow u2 p2)) | u1 == u2  = Just $ UnitPow u1 (p1 + p2)
    rw (UnitPow UnitlessLit _)                               = Just UnitlessLit
    rw (UnitPow UnitlessVar _)                               = Just UnitlessVar
    rw (UnitPow _ p) | p `approxEq` 0                        = Just UnitlessLit
    rw (UnitMul UnitlessLit u)                               = Just u
    rw (UnitMul u UnitlessLit)                               = Just u
    rw (UnitMul UnitlessVar u)                               = Just u
    rw (UnitMul u UnitlessVar)                               = Just u
    rw _                                                     = Nothing

flattenUnits :: UnitInfo -> [UnitInfo]
flattenUnits = map (uncurry UnitPow) . M.toList
             . M.filterWithKey (\ u _ -> u /= UnitlessLit && u /= UnitlessVar)
             . M.filter (not . approxEq 0)
             . M.fromListWith (+)
             . map (first simplifyUnits)
             . flatten
  where
    flatten (UnitMul u1 u2) = flatten u1 ++ flatten u2
    flatten (UnitPow u p)   = map (second (p*)) $ flatten u
    flatten u               = [(u, 1)]

approxEq a b = abs (b - a) < epsilon
epsilon = 0.001 -- arbitrary

--------------------------------------------------

-- Convert a set of constraints into a matrix of co-efficients, and a
-- reverse mapping of column numbers to units.
constraintsToMatrix :: Constraints -> (H.Matrix Double, [Int], A.Array Int UnitInfo)
constraintsToMatrix cons
  | all null lhs = (H.ident 0, [], A.listArray (0, 0) [])
  | otherwise = (augM, inconsists, A.listArray (0, length colElems - 1) colElems)
  where
    -- convert each constraint into the form (lhs, rhs)
    consPairs       = flattenConstraints cons
    -- ensure terms are on the correct side of the equal sign
    shiftedCons     = map shiftTerms consPairs
    lhs             = map fst shiftedCons
    rhs             = map snd shiftedCons
    (lhsM, lhsCols) = flattenedToMatrix lhs
    (rhsM, rhsCols) = flattenedToMatrix rhs
    colElems        = A.elems lhsCols ++ A.elems rhsCols
    augM            = if rows rhsM == 0 || cols rhsM == 0 then lhsM else if rows lhsM == 0 || cols lhsM == 0 then rhsM else fromBlocks [[lhsM, rhsM]]
    inconsists      = findInconsistentRows lhsM augM

constraintsToMatrices :: Constraints -> (H.Matrix Double, H.Matrix Double, [Int], A.Array Int UnitInfo, A.Array Int UnitInfo)
constraintsToMatrices cons
  | all null lhs = (H.ident 0, H.ident 0, [], A.listArray (0, 0) [], A.listArray (0, 0) [])
  | otherwise = (lhsM, rhsM, inconsists, lhsCols, rhsCols)
  where
    -- convert each constraint into the form (lhs, rhs)
    consPairs       = filter (uncurry (/=)) $ flattenConstraints cons
    -- ensure terms are on the correct side of the equal sign
    shiftedCons     = map shiftTerms consPairs
    lhs             = map fst shiftedCons
    rhs             = map snd shiftedCons
    (lhsM, lhsCols) = flattenedToMatrix lhs
    (rhsM, rhsCols) = flattenedToMatrix rhs
    augM            = if rows rhsM == 0 || cols rhsM == 0 then lhsM else if rows lhsM == 0 || cols lhsM == 0 then rhsM else fromBlocks [[lhsM, rhsM]]
    inconsists      = findInconsistentRows lhsM augM

-- [[UnitInfo]] is a list of flattened constraints
flattenedToMatrix :: [[UnitInfo]] -> (H.Matrix Double, A.Array Int UnitInfo)
flattenedToMatrix cons = (m, A.array (0, numCols - 1) (map swap uniqUnits))
  where
    m = runSTMatrix $ do
          m <- newMatrix 0 numRows numCols
          -- loop through all constraints
          forM_ (zip cons [0..]) $ \ (unitPows, row) -> do
            -- write co-efficients for the lhs of the constraint
            forM_ unitPows $ \ (UnitPow u k) -> do
              case M.lookup u colMap of
                Just col -> readMatrix m row col >>= (writeMatrix m row col . (+k))
                _        -> return ()
          return m
    -- identify and enumerate every unit uniquely
    uniqUnits = flip zip [0..] . map head . group . sortBy colSort $ [ u | UnitPow u _ <- concat cons ]
    -- map units to their unique column number
    colMap    = M.fromList uniqUnits
    numRows   = length cons
    numCols   = M.size colMap

negateCons = map (\ (UnitPow u k) -> UnitPow u (-k))

negatePosAbs (UnitPow (UnitParamPosAbs x) k) = UnitPow (UnitParamPosAbs x) (-k)
negatePosAbs u                               = u

colSort (UnitLiteral i) (UnitLiteral j)         = compare i j
colSort (UnitLiteral _) _                       = LT
colSort _ (UnitLiteral _)                       = GT
colSort (UnitParamPosAbs x) (UnitParamPosAbs y) = compare x y
colSort (UnitParamPosAbs _) _                   = GT
colSort _ (UnitParamPosAbs _)                   = LT
colSort x y                                     = compare x y

--------------------------------------------------

-- Units that should appear on the right-hand-side of the matrix during solving
isUnitRHS (UnitPow (UnitName _) _)        = True
isUnitRHS (UnitPow (UnitParamEAPAbs _) _) = True
isUnitRHS _                               = False

-- | Shift UnitNames/EAPAbs poly units to the RHS, and all else to the LHS.
shiftTerms :: ([UnitInfo], [UnitInfo]) -> ([UnitInfo], [UnitInfo])
shiftTerms (lhs, rhs) = (lhsOk ++ negateCons rhsShift, rhsOk ++ negateCons lhsShift)
  where
    (lhsOk, lhsShift) = partition (not . isUnitRHS) lhs
    (rhsOk, rhsShift) = partition isUnitRHS rhs

-- | Translate all constraints into a LHS, RHS side of units.
flattenConstraints :: Constraints -> [([UnitInfo], [UnitInfo])]
flattenConstraints = map (\ (ConEq u1 u2) -> (flattenUnits u1, flattenUnits u2))

--------------------------------------------------
-- Matrix solving functions based on HMatrix

-- | Returns True iff the given matrix in reduced row echelon form
-- represents an inconsistent system of linear equations
isInconsistentRREF a = a @@> (rows a - 1, cols a - 1) == 1 && rank (takeColumns (cols a - 1) (dropRows (rows a - 1) a))== 0

-- | Returns given matrix transformed into Reduced Row Echelon Form
rref :: H.Matrix Double -> H.Matrix Double
rref a = snd $ rrefMatrices' a 0 0 []

-- worker function
-- invariant: the matrix a is in rref except within the submatrix (j-k,j) to (n,n)
rrefMatrices' a j k mats
  -- Base cases:
  | j - k == n            = (mats, a)
  | j     == m            = (mats, a)

  -- When we haven't yet found the first non-zero number in the row, but we really need one:
  | a @@> (j - k, j) == 0 = case findIndex (/= 0) below of
    -- this column is all 0s below current row, must move onto the next column
    Nothing -> rrefMatrices' a (j + 1) (k + 1) mats
    -- we've found a row that has a non-zero element that can be swapped into this row
    Just i' -> rrefMatrices' (swapMat <> a) j k (swapMat:mats)
      where i       = j - k + i'
            swapMat = elemRowSwap n i (j - k)

  -- We have found a non-zero cell at (j - k, j), so transform it into
  -- a 1 if needed using elemRowMult, and then clear out any lingering
  -- non-zero values that might appear in the same column, using
  -- elemRowAdd:
  | otherwise             = rrefMatrices' a2 (j + 1) k mats2
  where
    n     = rows a
    m     = cols a
    below = getColumnBelow a (j - k, j)

    erm   = elemRowMult n (j - k) (recip (a @@> (j - k, j)))

    -- scale the row if the cell is not already equal to 1
    (a1, mats1) | a @@> (j - k, j) /= 1 = (erm <> a, erm:mats)
                | otherwise             = (a, mats)

    -- Locate any non-zero values in the same column as (j - k, j) and
    -- cancel them out. Optimisation: instead of constructing a
    -- separate elemRowAdd matrix for each cancellation that are then
    -- multiplied together, simply build a single matrix that cancels
    -- all of them out at the same time, using the ST Monad.
    findAdds _ m ms
      | isWritten = (new <> m, new:ms)
      | otherwise = (m, ms)
      where
        (isWritten, new) = runST $ do
          new <- newMatrix 0 n n :: ST s (STMatrix s Double)
          sequence [ writeMatrix new i' i' 1 | i' <- [0 .. (n - 1)] ]
          let f w i | i >= n            = return w
                    | i == j - k        = f w (i + 1)
                    | a @@> (i, j) == 0 = f w (i + 1)
                    | otherwise         = writeMatrix new i (j - k) (- (a @@> (i, j)))
                                          >> f True (i + 1)
          isWritten <- f False 0
          (isWritten,) `fmap` freezeMatrix new

    (a2, mats2) = findAdds 0 a1 mats1

-- Get a list of values that occur below (i, j) in the matrix a.
getColumnBelow a (i, j) = concat . H.toLists $ subMatrix (i, j) (n - i, 1) a
  where n = rows a

-- 'Elementary row operation' matrices
elemRowMult :: Int -> Int -> Double -> H.Matrix Double
elemRowMult n i k = diag (H.fromList (replicate i 1.0 ++ [k] ++ replicate (n - i - 1) 1.0))

elemRowSwap :: Int -> Int -> Int -> H.Matrix Double
elemRowSwap n i j
  | i == j          = ident n
  | i > j           = elemRowSwap n j i
  | otherwise       = extractRows ([0..i-1] ++ [j] ++ [i+1..j-1] ++ [i] ++ [j+1..n-1]) $ ident n


--------------------------------------------------

-- Worker functions:

findInconsistentRows :: H.Matrix Double -> H.Matrix Double -> [Int]
findInconsistentRows coA augA = [0..(rows augA - 1)] \\ consistent
  where
    consistent = head (filter (tryRows coA augA) (tails ( [0..(rows augA - 1)])) ++ [[]])

    -- Rouché–Capelli theorem is that if the rank of the coefficient
    -- matrix is not equal to the rank of the augmented matrix then
    -- the system of linear equations is inconsistent.
    tryRows coA augA ns = (rank coA' == rank augA')
      where
        coA'  = extractRows ns coA
        augA' = extractRows ns augA

extractRows = flip (?) -- hmatrix 0.17 changed interface
m @@> i = m `atIndex` i
