{-# LANGUAGE ImplicitParams #-}

module Camfort.Specification.Stencils.CheckSpec (spec) where

import qualified Data.ByteString.Internal as BS

import Camfort.Analysis.Annotations (unitAnnotation)
import Camfort.Specification.Stencils.CheckBackend
import Camfort.Specification.Stencils.CheckFrontend
  (CheckResult, stencilChecking)
import qualified Camfort.Specification.Stencils.Grammar as SYN
import Camfort.Specification.Stencils.Model
import Camfort.Specification.Stencils.Syntax

import qualified Language.Fortran.Analysis          as FA
import qualified Language.Fortran.Analysis.BBlocks  as FAB
import qualified Language.Fortran.Analysis.Renaming as FAR
import           Language.Fortran.Parser.Any (fortranParser)
import qualified Language.Fortran.Util.Position     as FU

import Test.Hspec

parseAndConvert x =
    let ?renv = []
    in case SYN.specParser x of
         Left  _  -> error "received stencil with invalid syntax in test"
         Right v  -> synToAst v

spec :: Spec
spec =
  describe "Stencils - Check" $ do
    describe "Parsing comments into internal rep" $ do
      it "parse and convert simple exact stencil (1)" $
          parseAndConvert "= stencil forward(depth=1, dim=1) :: x"
          `shouldBe`
            (Right $ Right [(["x"], Specification
             (Mult $ Exact (Spatial (Sum [Product [Forward 1 1 True]]))) True)])

      it "parse and convert simple exact stencil (2)" $
          parseAndConvert "= stencil forward(depth=1, dim=1) :: x, y, z"
          `shouldBe`
            (Right $ Right [(["x","y","z"], Specification
             (Mult $ Exact (Spatial (Sum [Product [Forward 1 1 True]]))) True)])

      it "parse and convert simple exact access spec (2)" $
          parseAndConvert "= access forward(depth=1, dim=1) :: x, y, z"
          `shouldBe`
            (Right $ Right [(["x","y","z"], Specification
             (Mult $ Exact (Spatial (Sum [Product [Forward 1 1 True]]))) False)])

      it "parse and convert simple exact stencil with nonpointed (2a)" $
          parseAndConvert "= stencil centered(depth=1, dim=2, nonpointed) :: x, y, z"
          `shouldBe`
            (Right $ Right [(["x","y","z"], Specification
             (Mult $ Exact (Spatial (Sum [Product [Centered 1 2 False]]))) True)])

      it "parse and convert simple upper bounded stencil (3)" $
          parseAndConvert "= stencil atmost, forward(depth=1, dim=1) :: x"
          `shouldBe`
            (Right $ Right [(["x"], Specification
             (Mult $ Bound Nothing (Just $ Spatial
                      (Sum [Product [Forward 1 1 True]]))) True)])

      it "parse and convert simple upper bounded access spec (3)" $
          parseAndConvert "= access atmost, forward(depth=1, dim=1) :: x"
          `shouldBe`
            (Right $ Right [(["x"], Specification
             (Mult $ Bound Nothing (Just $ Spatial
                      (Sum [Product [Forward 1 1 True]]))) False)])

      it "parse and convert simple lower bounded stencil (4)" $
          parseAndConvert "= stencil atleast, backward(depth=2, dim=1) :: x"
          `shouldBe`
            (Right $ Right [(["x"], Specification
             (Mult $ Bound (Just $ Spatial
                      (Sum [Product [Backward 2 1 True]])) Nothing) True)])

      it "parse and convert stencil requiring distribution (5)" $
          parseAndConvert "= stencil readonce, atleast, (forward(depth=1, dim=1) * ((centered(depth=1, dim=2)) + backward(depth=3, dim=4))) :: frob"
          `shouldBe`
            (Right $ Right [(["frob"], Specification
             (Once $ Bound (Just $ Spatial
                      (Sum [Product [Forward 1 1 True, Centered 1 2 True],
                            Product [Forward 1 1 True, Backward 3 4 True]])) Nothing) True)])

      it "rejects stencils with undefined regions" $
         parseAndConvert "= stencil r1 :: a"
         `shouldBe` (Left . regionNotInScope $ "r1")

      describe "stencils check" $ do
        checkTestShow exampleUnusedRegion
          "warns about unused regions"
          "(2:3)-(2:34)    Warning: Unused region 'r1'"
        checkTestShow exampleSimpleInvalidSyntax
          "warns about specification parse errors"
          "(2:3)-(2:16)    Could not parse specification at: \"... \"\n"
        checkTestShow exampleSimpleCorrect
          "recognises correct stencils"
          "(4:5)-(4:63)    Correct."
        checkTestShow exampleUnusedRegionWithOtherSpecs
          "provides reports in correct order"
          "(3:3)-(3:34)    Warning: Unused region 'r1'\n\
          \(5:5)-(5:63)    Correct.\n\
          \(9:5)-(9:52)    Not well specified.\n\
          \        Specification is:\n\
          \                stencil readOnce, (forward(depth=1, dim=1)) :: a\n\n\
          \        but at (10:5)-(10:17) the code behaves as\n\
          \                stencil readOnce, (forward(depth=1, dim=1, nonpointed)) :: a\n\n\
          \(12:3)-(12:16)    Could not parse specification at: \"... \"\n"

checkText text =
  either (error "received test input with invalid syntax")
     (stencilChecking . getBlocks . fmap (const unitAnnotation)) $ fortranParser text "example"
  where getBlocks = FAB.analyseBBlocks . FAR.analyseRenames . FA.initAnalysis

runCheck :: String -> CheckResult
runCheck = checkText . BS.packChars

checkTestShow :: String -> String -> String -> SpecWith ()
checkTestShow exampleText testDescription expected =
  it testDescription $ show (runCheck exampleText) `shouldBe` expected

exampleUnusedRegion :: String
exampleUnusedRegion =
  "program example\n\
  \  != region :: r1 = pointed(dim=1)\n\
  \end program"

exampleSimpleCorrect :: String
exampleSimpleCorrect =
  "program example\n\
  \  real, dimension(10) :: a\n\
  \  do i = 1, 10\n\
  \    != stencil readOnce, forward(depth=1,dim=1,nonpointed) :: a\n\
  \    a(i) = a(i+1)\n\
  \  end do\n\
  \end program"

exampleSimpleInvalidSyntax :: String
exampleSimpleInvalidSyntax =
  "program example\n\
  \  != stencil foo\n\
  \end program"

exampleUnusedRegionWithOtherSpecs :: String
exampleUnusedRegionWithOtherSpecs =
  "program example\n\
  \  real, dimension(10) :: a, b\n\
  \  != region :: r1 = pointed(dim=1)\n\
  \  do i = 1, 10\n\
  \    != stencil readOnce, forward(depth=1,dim=1,nonpointed) :: a\n\
  \    a(i) = a(i+1)\n\
  \  end do\n\
  \  do i = 1, 10\n\
  \    != stencil readOnce, forward(depth=1,dim=1) :: a\n\
  \    a(i) = a(i+1)\n\
  \  end do\n\
  \  != stencil foo\n\
  \end program"
