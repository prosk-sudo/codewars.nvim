--- Starter test fixtures per language, matching what codewars.com seeds when
--- you create a new kumite. Prefilled into the fixture split by `:CW kumite
--- new` so the panel starts from a working skeleton, not an empty buffer.
--- Keyed by Codewars language slug. Deliberately spans every language the
--- kata/kumite editor offers (see codewars.languages.filetypes), which is
--- wider than the training subset in codewars.config.langs.
local M = {}

M.templates = {
    python = [==[
import codewars_test as test
# TODO Write tests
import solution # or from solution import example

# test.assert_equals(actual, expected, [optional] message)
@test.describe("Example")
def test_group():
    @test.it("test case")
    def test_case():
        test.assert_equals(1 + 1, 2)
]==],

    javascript = [==[
// Since Node 10, we're using Mocha.
// You can use `chai` for assertions.
const chai = require("chai");
const assert = chai.assert;
// Uncomment the following line to disable truncating failure messages for deep equals, do:
// chai.config.truncateThreshold = 0;
// Since Node 12, we no longer include assertions from our deprecated custom test framework by default.
// Uncomment the following to use the old assertions:
// const Test = require("@codewars/test-compat");

describe("Solution", function() {
  it("should test for something", function() {
    // Test.assertEquals(1 + 1, 2);
    // assert.strictEqual(1 + 1, 2);
  });
});
]==],

    typescript = [==[
// See https://www.chaijs.com for how to use Chai.
import { assert } from "chai";

import { example } from "./solution";

// TODO Add your tests here
describe("example", function() {
  it("test", function() {
    // assert.strictEqual(1 + 1, 2);
  });
});
]==],

    coffeescript = [==[
# Create your own tests here. These are some of the methods available:
#  Test.expect(boolean, [optional] message)
#  Test.assertEquals(actual, expected, [optional] message)
#  Test.assertSimilar(actual, expected, [optional] message)
#  Test.assertNotEquals(actual, expected, [optional] message)
]==],

    ruby = [==[
# From Ruby 3.0, RSpec is used under the hood.
# See https://rspec.info/
# Defaults to the global `describe` for backwards compatibility, but `RSpec.desribe` works as well.
describe "Example" do
  it "should return the sum" do
    expect(add(1, 1)).to eq(2)
    # The following is still supported, but new tests should now use them.
    # Test.assert_equals(add(1, 1), 2)
  end
end
]==],

    java = [==[
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

// TODO: Replace examples and use TDD by writing your own tests

class SolutionTest {
    @Test
    void testSomething() {
        // assertEquals("expected", "actual");
    }
}
]==],

    csharp = [==[
namespace Solution {
  using NUnit.Framework;
  using System;

  // TODO: Replace examples and use TDD by writing your own tests

  [TestFixture]
  public class SolutionTest
  {
    [Test]
    public void MyTest()
    {
      Assert.AreEqual("expected", "actual");
    }
  }
}
]==],

    cpp = [==[
// TODO: Replace examples and use TDD by writing your own tests

Describe(any_group_name_you_want)
{
    It(should_do_something)
    {
        Assert::That("some value", Equals("another value"));
    }
};
]==],

    c = [==[
// TODO: Replace examples and use TDD by writing your own tests. The code provided here is just a how-to example.

#include <criterion/criterion.h>

// replace with the actual method being tested
int foo(int,int);

Test(the_multiply_function, should_pass_all_the_tests_provided) {
    cr_assert_eq(foo(1, 1), 1);
}
]==],

    go = [==[
// TODO: replace with your own tests (TDD). An example to get you started is included below.
// Ginkgo BDD Testing Framework <http://onsi.github.io/ginkgo/>
// Gomega Matcher Library <http://onsi.github.io/gomega/>

package kata_test
import (
  . "github.com/onsi/ginkgo"
  . "github.com/onsi/gomega"
  . "codewarrior/kata"
)
var _ = Describe("Test Example", func() {
//   It("should test that the solution returns the correct value", func() {
//     Expect(Solution(1)).To(Equal(2))
//   })
})
]==],

    rust = [==[
// Add your tests here.
// See https://doc.rust-lang.org/stable/rust-by-example/testing/unit_testing.html

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add(1, 2), 3);
    }
}
]==],

    haskell = [==[
module ExampleSpec where
-- Tests can be written using Hspec http://hspec.github.io/
-- Replace this with your own tests.

import Test.Hspec
import Example

-- `spec` of type `Spec` must exist
spec :: Spec
spec = do
    describe "add" $ do
        it "adds Nums" $ do
            (add 1 1) `shouldBe` (2 :: Integer)
]==],

    clojure = [==[
;; TODO: TDD using clojure.test framework
]==],

    elixir = [==[
# TODO: Replace examples and use TDD by writing your own tests

defmodule TestSolution do
  use ExUnit.Case

  test "some test description" do
    assert "actual" == "expected"
  end
end
]==],

    swift = [==[
import XCTest
// XCTest Spec Example:
// TODO: replace with your own tests (TDD), these are just how-to examples to get you started

class SolutionTest: XCTestCase {
    static var allTests = [
        ("Test Example", testExample),
    ]

    func testExample() {
        let actual = 1
        XCTAssertEqual(actual, 1)
    }
}

XCTMain([
    testCase(SolutionTest.allTests)
])
]==],

    kotlin = [==[
// You can test using JUnit or KotlinTest. JUnit is shown below
// TODO: replace this example test with your own, this is just here to demonstrate usage.

// TODO: replace with whatever your package is called
package solution

import kotlin.test.assertEquals
import org.junit.Test

class TestExample {
  @Test
  fun multiply() {
    assertEquals(4, multiply(2, 2))
  }
}
]==],

    scala = [==[
// You can test using ScalaTest (http://www.scalatest.org/).
import org.scalatest.flatspec.AnyFlatSpec
import org.scalatest.matchers.should.Matchers

// TODO: replace this example test with your own, this is just here to demonstrate usage.
// See http://www.scalatest.org/ to learn more.
class ExampleSpec extends AnyFlatSpec with Matchers {
  "multiply(2, 2)" should "return 4" in {
    Example.multiply(2, 2) should be (4)
  }
}
]==],

    php = [==[
<?php
use PHPUnit\Framework\TestCase;

// PHPUnit Test Examples:
// TODO: Replace examples and use TDD by writing your own tests
class ExampleTest extends TestCase
{
    // test function names should start with "test"
    public function testThatSomethingShouldHappen() {
      $this->assertEquals("a", "a");
      $this->assertEquals([0], [0]);
    }
}
]==],

    shell = [==[
# TODO: replace with your own tests (TDD). An example to get you started is included below.

# run the solution and store its result
# output = run_shell args: ['my_arg']

# describe "Solution" do
#   it "should return the argument passed in" do
#     expect(output).to include('my_arg')
#   end
# end
]==],

    lua = [==[
-- TODO: Replace examples and use TDD by writing your own tests
local solution = require 'solution'
describe("solution", function()
  it("test for something", function()
    assert.are.same("expected", solution.foo())
  end)
end)
]==],

    sql = [==[
# TODO: replace with your own tests (TDD), these are just how-to examples to get you started.

# Ruby/Rspec/Sequel Example:
# While the code section is pure SQL, for testing we use Ruby & Rspec.
# Sequel (https://github.com/jeremyevans/sequel) is used to setup the database and run queries.
# The connection is already made for you, use DB to access.

DB.create_table :items do
  primary_key :id
  String :name
  Float :price
end

items = DB[:items] # Create a dataset

# Populate the table
items.insert(:name => 'a', :price => 10)
items.insert(:name => 'b', :price => 35)
items.insert(:name => 'c', :price => 20)

results = run_sql

describe :items do
   it "should return 3 items" do
    expect(results.count).to eq 3
   end
end
]==],

    dart = [==[
// See https://pub.dartlang.org/packages/test
import "package:test/test.dart";
import "package:solution/solution.dart";

void main() {
  test("add", () {
    expect(add(1, 1), equals(2));
  });
}
]==],

    r = [==[
# You can test with testthat (http://r-pkgs.had.co.nz/tests.html#test-structure)
# TODO: replace with your own tests (TDD), these are just here to demonstrate usage.

test_that("example", {
  expect_equal(actual, expected)
})
]==],

    -- Intentionally empty: codewars.com seeds no example fixture for Nim.
    -- This is data, not a gap — do not invent one. (Its runner both writes
    -- an importable `solution` module and pre-imports it, so a hand-written
    -- Nim fixture needs neither `import solution` nor `import unittest`.)
    nim = "",

    crystal = [==[
# Spec example:
# TODO: replace with your own tests (TDD), these are just how-to examples.

describe "Solution" do
  it "should test something" do
     foo.should eq "bar"
  end
end
]==],

    julia = [==[
# FactCheck example:
# TODO: replace with your own tests (TDD), these are just how-to examples.
using FactCheck
facts("Testing basics") do
  @fact 1 --> 1
  @fact 2*2 --> 4
  @fact uppercase("foo") --> "FOO"
  @fact 2*[1,2,3] --> [2,4,6]
end
]==],

    racket = [==[
#lang racket
(require "solution.rkt")
(require rackunit
         codewars/rackunit)

;; codewars/rackunit provides `run-tests`.
;; See RackUnit documentation. https://docs.racket-lang.org/rackunit
(run-tests
  (test-suite
   "example"
   (test-case
    "add"
    (check-equal? (add 1 1) 2))))
]==],

    ocaml = [==[
(* TODO: replace with your own tests, these are just how-to examples.
 * OUnit Spec example:
 * See https://ocaml.org/p/ounit2/2.2.3/doc/index.html for documentation
 * Available packages: https://docs.codewars.com/languages/ocaml
 *)

open Solution
open OUnit
let suite = [
    "Suite Name" >:::
        [
            "Test Name" >:: (fun _ ->
                assert_equal "Expected" "Actual" ~printer:Fun.id ~msg:"test"
            )
        ]
    ]
]==],

    fsharp = [==[
module ExampleTests

open ExampleSolution
// NUnit is used to test F# 6.0.
open NUnit.Framework

[<Test>]
let TestAdd() =
    Assert.AreEqual(2, add 1 1)

[<TestFixture>]
type FixedTests() =
    [<Test>]
    member this.TestOne() =
        Assert.AreEqual(1, add 0 1)
]==],

    erlang = [==[
% Test using EUnit (http://erlang.org/doc/apps/eunit/chapter.html)
% TODO: replace with your own tests (TDD), these are just here to demonstrate usage.
-module(example_tests).
-include_lib("eunit/include/eunit.hrl").

example_test_() ->
  {"Two Oldest Ages",
    [{"returns [45, 87] for [1,5,87,45,8,8]", ?_assertMatch([45, 87], [45])}]}.
]==],

    fortran = [==[
! CW2 example
program TestCases
  use CW2
  use Solution
implicit none
  call describe("add")
    call it("adds integers")
      call assertEquals(2, add(1, 1))
    call endContext()
  call endContext()
end program
]==],

    nasm = [==[
; this is just an example. See https://docs.codewars.com/languages/nasm
#include <criterion/criterion.h>
int add(int, int);
Test(add_test, should_add_integers) {
  cr_assert_eq(add(1, 1), 2);
}
]==],

    cobol = [==[
      * See https://github.com/codewars/cobol-test
       identification division.
       program-id. tests.

       data division.
       working-storage section.
       01  arg1        pic s9(5).
       01  arg2        pic s9(5).
       01  arg1-str    pic -9(5).
       01  arg2-str    pic -9(5).
       01  result      pic s9(6).
       01  expected    pic s9(6).

       procedure division.
      * Fixed Tests
           testsuite 'Fixed Tests'.
           testcase 'Test 1'.
           move 3 to arg1
           move -5 to arg2
           call 'solution' using
               by content arg1 arg2
               by reference result
           expect result to be -2.0.

           end tests.

       end program tests.
]==],

    d = [==[
module solution_test;

import solution : add;

// fluent asserts is supported
version(unittest) import fluent.asserts;

// Name the unittest block
@("add returns the sum")
unittest {
    add(1, 1).should.equal(2).because("1 + 1 == 2");
    assert(add(1, 1) == 2);
}
]==],

    prolog = [==[
% plunit can be used to test solution
:- begin_tests(example).
:- include(example).

test(example_test) :-
        X is 1+1,
        assertion(X == 2).

:- end_tests(example).
]==],

    factor = [==[
! Use vocabulary tools.testest for testing.
! See https://github.com/codewars/testest

USING: example tools.testest ;
IN: example.tests

: run-tests ( -- )
  "Example" describe#{
    "test case" it#{
      <{ 1 1 example ->  1 }>
    }#
  }#
;

MAIN: run-tests
]==],

    groovy = [==[
// You can test using JUnit or Spock. JUnit is shown below
// TODO: replace this example test with your own, this is just here to demonstrate usage.
import org.junit.Test

class TestExample {
  @Test
  void returnsProduct() {
    assert Example.multiply(2, 2) == 4
  }
}
]==],

    perl = [==[
# You can use `Test::More` to write tests.
# https://metacpan.org/pod/Test::More
use Test::Most;

# The name of the solution package is inferred from the code.
use Solution;

subtest "examples" => sub {
  is(Solution::add(1, 1), 2);
};

done_testing();
]==],

    powershell = [==[
# You can test with Pester (https://github.com/pester/Pester)
# TODO: replace with your own tests (TDD), these are just here to demonstrate usage.
BeforeAll {
  . $PSCommandPath.Replace('.Tests.ps1', '.ps1')
}

Describe "Add-Numbers" {
  It "adds positive numbers" {
    Add-Numbers 1 1 | Should -Be 2
  }
}
]==],

    elm = [==[
module ExampleTest exposing (..)
-- Codewars uses [elm-test](https://package.elm-lang.org/packages/elm-explorations/test/1.1.0).
-- Replace this with your own tests.

import Expect exposing (Expectation)
import Test exposing (..)

import Example

suite : Test
suite =
  describe "Example"
    [ test "add" <|
      \_ -> (Example.add 1 1) |> Expect.equal 2
    ]
]==],

    reason = [==[
/* You can write tests using Jest.
 * See https://github.com/glennsl/bs-jest
 * Replace with your own tests.
 */
open Jest;

describe("add", () => {
  open Expect;
  test("1 + 1", () =>
    expect(Solution.add(1, 1)) |> toBe(2));
});
]==],

    bf = [==[
// You can use the Mocha (JavaScript) framework for testing BF.
// TODO: replace with your own tests (TDD), these are just here to demonstrate usage.

describe("Your Test Suite", function () {
  it("should return Hello World!", function () {
    // use runBF() to run your program, you can pass it arguments
    Test.assertEquals(runBF(), "Hello World!");
  });
});
]==],

    pascal = [==[
unit ExampleTests;
// Tests are written with [FPTest](https://github.com/graemeg/fptest).

{$mode objfpc}{$H+}

interface

uses
  TestFramework,
  Example;

type TExampleTests = class(TTestCase)
  published
    procedure TestAdd;
end;

procedure RegisterTests;

implementation

procedure RegisterTests;
begin
  TestFramework.RegisterTest(TExampleTests.Suite);
end;

procedure TExampleTests.TestAdd;
begin
  CheckEquals(2, Add(1, 1));
end;
end.
]==],

    objc = [==[
// TODO: replace with your own tests, these are just how-to examples.
// Codewars uses UnitKit unit testing framework.
// See https://docs.codewars.com/languages/objc/unitkit
@implementation TestSuite
- (void) testsIfReturnsActual
{
  UKStringsEqual(@"expected", Solution(@"value"));
  UKStringsNotEqual(@"expected", Solution(@"value"));
}
@end
]==],

    haxe = [==[
// Tests are written using https://github.com/haxe-utest/utest
import utest.Assert;
import Solution;

class SolutionTest extends utest.Test {
  function testExample() {
    Assert.equals(2, Example.add(1, 1));
  }
}
]==],

    riscv = [==[
// Tests for RISC-V are written in C with Cgreen.
// See <https://cgreen-devs.github.io/cgreen/cgreen-guide-en.html>.
#include <cgreen/cgreen.h>
#include <stdlib.h>
#include <time.h>
#include <stddef.h>

int add(int, int);

// `Describe`, `BeforeEach`, and `AfterEach` are required.
Describe(Example);
BeforeEach(Example) {}
AfterEach(Example) {}

Ensure(Example, works_for_fixed_tests) {
  assert_that(add(1, 1), is_equal_to(2));
}

// `solution_tests` to create a test suite is required.
TestSuite *solution_tests() {
  TestSuite *suite = create_test_suite();
  add_test_with_context(suite, Example, works_for_fixed_tests);
  return suite;
}
]==],

    coq = [==[
Require Solution.
Require Import Preloaded.
From CW Require Import Loader.

CWGroup "Solution.example".
  CWTest "should have the correct type".
    CWAssert Solution.example : (forall (A : Type) (a b c : A),
      a = b -> b = c -> a = c).
  CWTest "should be closed under the global context".
    CWAssert Solution.example Assumes.
CWEndGroup.
]==],

    forth = [==[
\ ttester.fs with extension for Codewars
\ See https://github.com/codewars/ttester-codewars

s" example" describe#{
  s" returns sum" it#{
    <{ 1 1 example -> 2 }>
  }#
}#
]==],

    raku = [==[
use v6;
# You can write tests using the standard Test module.
# https://docs.raku.org/language/testing
use Test;
# The name of the solution module is inferred from the code.
use Solution;

subtest "examples", {
    is(add(1, 1), 2);
}
done-testing;
]==],

    purescript = [==[
module ExampleSpec where
-- Tests can be written using spec https://purescript-spec.github.io/purescript-spec
-- Replace this with your own tests.

import Prelude

import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

import Example (add')

spec :: Spec Unit
spec =
  describe "Example" do
    describe "add'" do
      it "returns sum" do
        (add' 1 1) `shouldEqual` 2
]==],

    agda = [==[
{-# OPTIONS --safe #-}
module Test where

open import Example

check : {A : Set} {a b c : A} → a ≡ b → b ≡ c → a ≡ c
check = _⇆_
]==],

    lean = [==[
import Preloaded Solution

theorem submission : SUBMISSION := immediate
#print axioms submission
]==],

    commonlisp = [==[
(in-package #:cl-user)
(defpackage #:challenge/tests/solution
  (:use #:cl
        #:rove
        #:challenge/solution))
(in-package #:challenge/tests/solution)
; Solution can be imported from `challenge/solution`.

; Write tests with Rove (https://github.com/fukamachi/rove).
(deftest test-solution
  (testing "add"
    (ok (= (add 1 1) 2))))
]==],

    idris = [==[
module ExampleSpec
-- Tests can be written using [specdris](https://github.com/pheymann/specdris)
-- `specSuite : IO ()` is required.

import Specdris.Spec
import Example

%access export
%default total

specSuite : IO ()
specSuite = spec $ do
  describe "add" $ do
    it "adds two natural numbers" $ do
      (1 `add` 1) `shouldBe` 2
]==],

    solidity = [==[
// See https://hardhat.org/tutorial/testing-contracts
const { expect } = require("chai");

describe("Token contract", function () {
  it("Deployment should assign the total supply of tokens to the owner", async function () {
    const [owner] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("Token");
    const token = await Token.deploy();
    const ownerBalance = await token.balanceOf(owner.address);
    expect(await token.totalSupply()).to.equal(ownerBalance);
  });
});
]==],

    vb = [==[
Imports NUnit.Framework

<TestFixture>
Public Class AdderTest
    <Test>
    Public Sub ShouldAddInts()
        Assert.AreEqual(2, Adder.Add(1, 1))
    End Sub
End Class
]==],

    cfml = [==[
// https://testbox.ortusbooks.com/
component extends="CodewarsBaseSpec" {
    // Submitted solution is written to Solution.cfc
    function beforeAll(){
        SUT = createObject( 'Solution' );
    }

    function run(){
        describe( "Example", function(){
            it( "returns sum", function(){
                expect( SUT.add(1, 1) ).toBe( 2 );
            });
        });
    }
}
]==],

    lambdacalc = [==[
import { assert, LC, getSolution } from "./lc-test.js";

LC.configure({ purity: "Let", numEncoding: "Church", verbosity: "Concise" });
const { multiply } = LC.compile(getSolution());

describe("Multiply", () => {
  it("example tests", () => {
    assert.numEql( multiply(7)(7), 49 );
    assert.numEql( multiply(11)(11), 121 );
  });
});
]==],
}

--- The starter fixture for a language slug (empty string when none).
--- Leading newline trimmed so the buffer starts at the first real line.
---@param lang string
---@return string
function M.get(lang)
    local t = M.templates[lang]
    if not t or t == "" then
        return ""
    end
    return (t:gsub("^\n", ""))
end

return M
