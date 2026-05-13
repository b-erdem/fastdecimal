defmodule FastDecimal.EdgeCasesTest do
  @moduledoc """
  Specific edge cases that history has shown are easy to get wrong. Each test
  here exists because a real implementation bug would slip past the "normal
  case" tests.
  """

  use ExUnit.Case, async: true

  import FastDecimal, only: [sigil_d: 2]

  describe "zero handling" do
    test "0 + 0 in many shapes" do
      zeros = [~d"0", ~d"0.0", ~d"0.00", FastDecimal.new(0, 5), FastDecimal.new(0, -10)]

      for a <- zeros, b <- zeros do
        result = FastDecimal.add(a, b)

        assert FastDecimal.equal?(result, ~d"0"),
               "#{inspect(a)} + #{inspect(b)} should equal 0, got #{inspect(result)}"
      end
    end

    test "x * 0 == 0 across all magnitudes" do
      values = [~d"1", ~d"1000000", ~d"-1.5", ~d"0.0001", ~d"1e50"]

      for v <- values do
        assert FastDecimal.equal?(FastDecimal.mult(v, ~d"0"), ~d"0")
        assert FastDecimal.equal?(FastDecimal.mult(~d"0", v), ~d"0")
      end
    end

    test "zero division raises (matches Decimal behavior)" do
      assert_raise ArithmeticError, fn -> FastDecimal.div(~d"1", ~d"0") end
      assert_raise ArithmeticError, fn -> FastDecimal.div(~d"0", ~d"0") end
      assert_raise ArithmeticError, fn -> FastDecimal.div_int(~d"5", ~d"0") end
      assert_raise ArithmeticError, fn -> FastDecimal.rem(~d"5", ~d"0") end
    end

    test "zero comparison" do
      assert FastDecimal.compare(~d"0", ~d"0.0") == :eq
      assert FastDecimal.compare(~d"0", ~d"-0") == :eq
      assert FastDecimal.compare(~d"0", ~d"0.0000") == :eq
    end

    test "predicates on zero" do
      assert FastDecimal.zero?(~d"0")
      assert FastDecimal.zero?(~d"0.0")
      assert FastDecimal.zero?(~d"-0")
      assert FastDecimal.zero?(~d"0.0000")
      refute FastDecimal.positive?(~d"0")
      refute FastDecimal.negative?(~d"0")
    end
  end

  describe "bignum boundary (~60-bit BEAM immediate threshold)" do
    @max_imm 1_152_921_504_606_846_975

    test "values just below immediate threshold stay small" do
      a = FastDecimal.new(@max_imm)
      b = FastDecimal.new(1)
      result = FastDecimal.add(a, b)
      # No assertion on representation — just verify arithmetic works
      assert FastDecimal.equal?(result, FastDecimal.new(@max_imm + 1))
    end

    test "addition crossing the bignum boundary" do
      half = Kernel.div(@max_imm, 2) + 1
      a = FastDecimal.new(half)
      result = FastDecimal.add(a, a)
      assert FastDecimal.equal?(result, FastDecimal.new(half * 2))
    end

    test "multiplication producing bignum" do
      a = FastDecimal.new(10_000_000_000)
      result = FastDecimal.mult(a, a)
      assert FastDecimal.equal?(result, FastDecimal.new(100_000_000_000_000_000_000))
    end

    test "30-digit coefficient arithmetic" do
      a = FastDecimal.new(String.duplicate("9", 30))
      b = FastDecimal.new("1")
      result = FastDecimal.add(a, b)
      expected_str = "1" <> String.duplicate("0", 30)
      assert FastDecimal.equal?(result, FastDecimal.new(expected_str))
    end
  end

  describe "exponent alignment edges" do
    test "wildly different exponents in add" do
      a = ~d"1"
      b = FastDecimal.new(1, -50)
      result = FastDecimal.add(a, b)
      # 1 + 1e-50 — should keep both, result has exp -50
      assert result.exp == -50
      assert is_integer(result.coef)
    end

    test "huge positive exponent" do
      a = FastDecimal.new(1, 100)
      b = FastDecimal.new(1, 0)
      result = FastDecimal.add(a, b)
      # 10^100 + 1 == "1" + "0"*99 + "1"
      expected = FastDecimal.new("1" <> String.duplicate("0", 99) <> "1")
      assert FastDecimal.equal?(result, expected)
    end

    test "subtraction near-equal values producing small result" do
      a = FastDecimal.new("1.000000001")
      b = FastDecimal.new("1.000000000")
      diff = FastDecimal.sub(a, b)
      assert FastDecimal.equal?(diff, FastDecimal.new("0.000000001"))
    end

    test "mult of values with very different magnitudes" do
      # 10^50
      a = FastDecimal.new(1, 50)
      # 10^-50
      b = FastDecimal.new(1, -50)
      result = FastDecimal.mult(a, b)
      assert FastDecimal.equal?(result, ~d"1")
    end
  end

  describe "rounding edge cases" do
    test "rounding exactly on the boundary (.5)" do
      # Banker's: rounds to even
      assert FastDecimal.equal?(FastDecimal.round(~d"0.5", 0), ~d"0")
      assert FastDecimal.equal?(FastDecimal.round(~d"1.5", 0), ~d"2")
      assert FastDecimal.equal?(FastDecimal.round(~d"2.5", 0), ~d"2")
      assert FastDecimal.equal?(FastDecimal.round(~d"3.5", 0), ~d"4")
      assert FastDecimal.equal?(FastDecimal.round(~d"4.5", 0), ~d"4")
    end

    test "round preserves negativity sign through different modes" do
      neg = ~d"-1.5"

      assert FastDecimal.negative?(FastDecimal.round(neg, 0, :half_even))
      assert FastDecimal.negative?(FastDecimal.round(neg, 0, :half_up))
      assert FastDecimal.negative?(FastDecimal.round(neg, 0, :floor))
      # :down rounds toward zero, so -1.5 -> -1 (still negative)
      assert FastDecimal.negative?(FastDecimal.round(neg, 0, :down))
    end

    test "round with very high precision is no-op when input has fewer digits" do
      assert FastDecimal.equal?(FastDecimal.round(~d"1.23", 100), ~d"1.23")
      assert FastDecimal.equal?(FastDecimal.round(~d"42", 50), ~d"42")
    end

    test "round of zero is zero" do
      assert FastDecimal.equal?(FastDecimal.round(~d"0", 5), ~d"0")
      assert FastDecimal.equal?(FastDecimal.round(~d"0.0000", 2), ~d"0")
    end

    test "round near 9.99..." do
      # The carry case
      assert FastDecimal.equal?(FastDecimal.round(~d"9.9999", 2), ~d"10.00")
      assert FastDecimal.equal?(FastDecimal.round(~d"99.99", 1), ~d"100.0")
    end
  end

  describe "division edge cases" do
    test "exact division has finite repr" do
      r = FastDecimal.div(~d"1", ~d"4", precision: 28)
      assert FastDecimal.equal?(r, ~d"0.25")
    end

    test "non-terminating division gives full precision" do
      r = FastDecimal.div(~d"1", ~d"3", precision: 28)
      str = FastDecimal.to_string(r)
      # "0.333..." with 28 fractional digits
      assert String.starts_with?(str, "0.")
      # "0." + 28 digits
      assert String.length(str) == 30
    end

    test "div by 1 is identity" do
      for s <- ["0", "1", "1.23", "-42.5", "1000000"] do
        d = FastDecimal.new(s)
        assert FastDecimal.equal?(FastDecimal.div(d, ~d"1", precision: 28), d)
      end
    end

    test "div_int truncates the right way for negatives" do
      # Like Kernel.div: rounds toward zero, NOT toward -∞
      assert FastDecimal.equal?(FastDecimal.div_int(~d"-7", ~d"2"), ~d"-3")
      assert FastDecimal.equal?(FastDecimal.div_int(~d"7", ~d"-2"), ~d"-3")
      assert FastDecimal.equal?(FastDecimal.div_int(~d"-7", ~d"-2"), ~d"3")
    end

    test "rem has the same sign as the dividend (matches Kernel.rem)" do
      {_, r1} = FastDecimal.div_rem(~d"-7", ~d"2")
      assert FastDecimal.negative?(r1)

      {_, r2} = FastDecimal.div_rem(~d"7", ~d"-2")
      assert FastDecimal.positive?(r2)
    end
  end

  describe "sqrt edge cases" do
    test "sqrt(1) = 1 exactly" do
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"1"), ~d"1")
    end

    test "sqrt of small fractions" do
      r = FastDecimal.sqrt(~d"0.25", precision: 28)
      assert FastDecimal.equal?(r, ~d"0.5")
    end

    test "sqrt of large powers of 100" do
      r = FastDecimal.sqrt(~d"10000")
      assert FastDecimal.equal?(r, ~d"100")
    end

    test "sqrt of odd-exponent" do
      # 0.2 = 2 * 10^-1 (odd exponent)
      r = FastDecimal.sqrt(~d"0.2", precision: 10)
      # sqrt(0.2) ≈ 0.4472135954
      assert FastDecimal.lt?(
               FastDecimal.abs(FastDecimal.sub(r, FastDecimal.new("0.4472135955"))),
               FastDecimal.new("0.0000000002")
             )
    end
  end

  describe "comparison edge cases" do
    test "1.10 == 1.1 (different representations, same value)" do
      assert FastDecimal.equal?(~d"1.10", ~d"1.1")
      assert FastDecimal.equal?(~d"1.100", ~d"1.10")
      assert FastDecimal.equal?(~d"1.10000", ~d"1.1")
    end

    test "compare across signs" do
      assert FastDecimal.compare(~d"-1", ~d"1") == :lt
      assert FastDecimal.compare(~d"1", ~d"-1") == :gt
      assert FastDecimal.compare(~d"-0.001", ~d"0.001") == :lt
    end

    test "compare very close values" do
      assert FastDecimal.compare(~d"1.000000001", ~d"1.000000002") == :lt
      assert FastDecimal.compare(~d"1.0000000001", ~d"1") == :gt
    end

    test "compare with very different exponents" do
      assert FastDecimal.compare(FastDecimal.new(1, 100), FastDecimal.new(1, 0)) == :gt
      assert FastDecimal.compare(FastDecimal.new(1, -100), FastDecimal.new(1, 0)) == :lt
    end
  end

  describe "to_string edge cases" do
    test "all the zero forms" do
      assert FastDecimal.to_string(~d"0") == "0"
      assert FastDecimal.to_string(~d"0.0") == "0.0"
      assert FastDecimal.to_string(~d"0.00") == "0.00"
      assert FastDecimal.to_string(FastDecimal.new(0, 5)) == "0"
    end

    test "leading zeros in fractional output" do
      assert FastDecimal.to_string(FastDecimal.new(1, -5)) == "0.00001"
      assert FastDecimal.to_string(FastDecimal.new(-1, -5)) == "-0.00001"
      assert FastDecimal.to_string(FastDecimal.new(1, -10)) == "0.0000000001"
    end

    test "preserves coefficient trailing zeros" do
      assert FastDecimal.to_string(FastDecimal.new(100, -2)) == "1.00"
      assert FastDecimal.to_string(FastDecimal.new(1_000_000, -3)) == "1000.000"
    end

    test "scientific with very small / very large" do
      assert FastDecimal.to_string(FastDecimal.new(1, -100), :scientific) == "1E-100"
      assert FastDecimal.to_string(FastDecimal.new(1, 100), :scientific) == "1E+100"
    end
  end
end
