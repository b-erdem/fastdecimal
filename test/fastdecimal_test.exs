defmodule FastDecimalTest do
  use ExUnit.Case, async: true
  doctest FastDecimal

  import FastDecimal, only: [sigil_d: 2]

  describe "construction" do
    test "new/1 with string" do
      assert FastDecimal.new("1.23") == %FastDecimal{coef: 123, exp: -2}
      assert FastDecimal.new("0") == %FastDecimal{coef: 0, exp: 0}
      assert FastDecimal.new("-0.001") == %FastDecimal{coef: -1, exp: -3}
      assert FastDecimal.new("1000") == %FastDecimal{coef: 1000, exp: 0}
      assert FastDecimal.new("+42") == %FastDecimal{coef: 42, exp: 0}
    end

    test "new/1 with integer" do
      assert FastDecimal.new(42) == %FastDecimal{coef: 42, exp: 0}
      assert FastDecimal.new(-100) == %FastDecimal{coef: -100, exp: 0}
    end

    test "new/2 with coef + exp" do
      assert FastDecimal.new(123, -2) == %FastDecimal{coef: 123, exp: -2}
    end

    test "new/1 with invalid string raises" do
      assert_raise ArgumentError, fn -> FastDecimal.new("abc") end
      assert_raise ArgumentError, fn -> FastDecimal.new("") end
      assert_raise ArgumentError, fn -> FastDecimal.new("1.2.3") end
      assert_raise ArgumentError, fn -> FastDecimal.new("1..2") end
    end

    test "leading-dot strings are accepted (\".5\" == \"0.5\")" do
      assert FastDecimal.new(".5") == %FastDecimal{coef: 5, exp: -1}
    end

    test "parse/1 returns ok/error tuple" do
      assert FastDecimal.parse("1.23") == {:ok, ~d"1.23"}
      assert FastDecimal.parse("abc") == :error
      assert FastDecimal.parse("") == :error
    end

    test "sigil parses at compile time" do
      assert ~d"1.23" == %FastDecimal{coef: 123, exp: -2}
      assert ~d"-0.5" == %FastDecimal{coef: -5, exp: -1}
      assert ~d"1000000.000001" == %FastDecimal{coef: 1_000_000_000_001, exp: -6}
    end
  end

  describe "add/2" do
    test "same exponent" do
      assert FastDecimal.add(~d"1.23", ~d"4.56") |> FastDecimal.equal?(~d"5.79")
    end

    test "different exponents" do
      assert FastDecimal.add(~d"1.23", ~d"4.567") |> FastDecimal.equal?(~d"5.797")
      assert FastDecimal.add(~d"4.567", ~d"1.23") |> FastDecimal.equal?(~d"5.797")
    end

    test "negative numbers" do
      assert FastDecimal.add(~d"-1.5", ~d"2.0") |> FastDecimal.equal?(~d"0.5")
      assert FastDecimal.add(~d"-1.5", ~d"-2.5") |> FastDecimal.equal?(~d"-4.0")
    end

    test "with zero" do
      assert FastDecimal.add(~d"0", ~d"1.23") |> FastDecimal.equal?(~d"1.23")
      assert FastDecimal.add(~d"1.23", ~d"0") |> FastDecimal.equal?(~d"1.23")
    end

    test "cross-checked against Decimal" do
      for {a, b} <- [
            {"1.23", "4.567"},
            {"-100.5", "0.005"},
            {"999999999.99", "0.01"},
            {"1.0000000001", "1.0000000002"}
          ] do
        got = FastDecimal.new(a) |> FastDecimal.add(FastDecimal.new(b)) |> FastDecimal.to_string()

        expected =
          Decimal.add(Decimal.new(a), Decimal.new(b))
          |> Decimal.normalize()
          |> Decimal.to_string(:normal)

        assert FastDecimal.equal?(FastDecimal.new(got), FastDecimal.new(expected)),
               "#{a} + #{b}: got #{got}, decimal #{expected}"
      end
    end
  end

  describe "sub/2" do
    test "basic subtraction" do
      assert FastDecimal.sub(~d"5", ~d"3") |> FastDecimal.equal?(~d"2")
      assert FastDecimal.sub(~d"1.23", ~d"4.567") |> FastDecimal.equal?(~d"-3.337")
    end

    test "cross-checked against Decimal" do
      for {a, b} <- [{"10", "3.14"}, {"-5.5", "-2.2"}, {"1.0001", "1"}] do
        got = FastDecimal.new(a) |> FastDecimal.sub(FastDecimal.new(b)) |> FastDecimal.to_string()
        expected = Decimal.sub(Decimal.new(a), Decimal.new(b)) |> Decimal.to_string(:normal)

        assert FastDecimal.equal?(FastDecimal.new(got), FastDecimal.new(expected)),
               "#{a} - #{b}: got #{got}, decimal #{expected}"
      end
    end
  end

  describe "mult/2" do
    test "basic multiplication" do
      assert FastDecimal.mult(~d"1.5", ~d"2") |> FastDecimal.equal?(~d"3.0")
      assert FastDecimal.mult(~d"0.1", ~d"0.2") |> FastDecimal.equal?(~d"0.02")
    end

    test "with zero" do
      assert FastDecimal.mult(~d"0", ~d"1.23") |> FastDecimal.equal?(~d"0")
    end

    test "cross-checked against Decimal" do
      for {a, b} <- [{"1.23", "4.567"}, {"-2.5", "4"}, {"1.000001", "1.000001"}] do
        got =
          FastDecimal.new(a) |> FastDecimal.mult(FastDecimal.new(b)) |> FastDecimal.to_string()

        expected = Decimal.mult(Decimal.new(a), Decimal.new(b)) |> Decimal.to_string(:normal)

        assert FastDecimal.equal?(FastDecimal.new(got), FastDecimal.new(expected)),
               "#{a} * #{b}: got #{got}, decimal #{expected}"
      end
    end
  end

  describe "div/3" do
    test "exact division" do
      assert FastDecimal.div(~d"10", ~d"2", precision: 5) |> FastDecimal.equal?(~d"5")
      assert FastDecimal.div(~d"1", ~d"4", precision: 5) |> FastDecimal.equal?(~d"0.25")
    end

    test "non-terminating, default half_even" do
      result = FastDecimal.div(~d"10", ~d"3", precision: 5)
      assert FastDecimal.equal?(result, ~d"3.3333")
    end

    test "raises on division by zero" do
      assert_raise ArithmeticError, fn -> FastDecimal.div(~d"1", ~d"0") end
    end

    test "rounding modes on 7/2 (precision 1)" do
      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :half_even) ==
               FastDecimal.new("4")

      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :half_up) ==
               FastDecimal.new("4")

      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :down) ==
               FastDecimal.new("3")

      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :up) ==
               FastDecimal.new("4")

      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :floor) ==
               FastDecimal.new("3")

      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :ceiling) ==
               FastDecimal.new("4")
    end

    test "banker's rounding (half_even) ties to even" do
      # 2.5 → 2 (round to even)
      assert FastDecimal.div(~d"5", ~d"2", precision: 1, rounding: :half_even) ==
               FastDecimal.new("2")

      # 3.5 → 4 (round to even)
      assert FastDecimal.div(~d"7", ~d"2", precision: 1, rounding: :half_even) ==
               FastDecimal.new("4")
    end

    test "negative dividend with half_up" do
      assert FastDecimal.div(~d"-7", ~d"2", precision: 1, rounding: :half_up) ==
               FastDecimal.new("-4")
    end

    test "1/7 precision 5" do
      assert FastDecimal.div(~d"1", ~d"7", precision: 5) |> FastDecimal.equal?(~d"0.14286")
    end
  end

  describe "negate/1 and abs/1" do
    test "negate flips sign" do
      assert FastDecimal.negate(~d"1.23") == %FastDecimal{coef: -123, exp: -2}
      assert FastDecimal.negate(~d"-1.23") == %FastDecimal{coef: 123, exp: -2}
      assert FastDecimal.negate(~d"0") == %FastDecimal{coef: 0, exp: 0}
    end

    test "abs always non-negative" do
      assert FastDecimal.abs(~d"1.23") == %FastDecimal{coef: 123, exp: -2}
      assert FastDecimal.abs(~d"-1.23") == %FastDecimal{coef: 123, exp: -2}
    end
  end

  describe "compare/2, equal?/2, min/max" do
    test "compare basic" do
      assert FastDecimal.compare(~d"1", ~d"2") == :lt
      assert FastDecimal.compare(~d"2", ~d"1") == :gt
      assert FastDecimal.compare(~d"1", ~d"1") == :eq
    end

    test "compare across exponents (1.10 == 1.1)" do
      assert FastDecimal.compare(~d"1.10", ~d"1.1") == :eq
      assert FastDecimal.compare(~d"1.10000", ~d"1.1") == :eq
      assert FastDecimal.equal?(~d"1.10000", ~d"1.1")
    end

    test "compare with negatives" do
      assert FastDecimal.compare(~d"-1", ~d"1") == :lt
      assert FastDecimal.compare(~d"-2", ~d"-1") == :lt
    end

    test "min/max" do
      assert FastDecimal.min(~d"1.5", ~d"2.5") == ~d"1.5"
      assert FastDecimal.max(~d"1.5", ~d"2.5") == ~d"2.5"
      assert FastDecimal.min(~d"-1", ~d"1") == ~d"-1"
    end

    test "lt? and gt?" do
      assert FastDecimal.lt?(~d"1", ~d"2")
      refute FastDecimal.lt?(~d"2", ~d"1")
      assert FastDecimal.gt?(~d"2", ~d"1")
      refute FastDecimal.gt?(~d"1", ~d"2")
    end
  end

  describe "predicates" do
    test "zero?" do
      assert FastDecimal.zero?(~d"0")
      assert FastDecimal.zero?(~d"0.00")
      assert FastDecimal.zero?(~d"-0")
      refute FastDecimal.zero?(~d"0.01")
    end

    test "positive? / negative?" do
      assert FastDecimal.positive?(~d"1")
      refute FastDecimal.positive?(~d"-1")
      refute FastDecimal.positive?(~d"0")

      assert FastDecimal.negative?(~d"-1")
      refute FastDecimal.negative?(~d"1")
      refute FastDecimal.negative?(~d"0")
    end
  end

  describe "to_string/1" do
    test "integer values" do
      assert FastDecimal.to_string(~d"0") == "0"
      assert FastDecimal.to_string(~d"42") == "42"
      assert FastDecimal.to_string(~d"-42") == "-42"
      assert FastDecimal.to_string(~d"1000000") == "1000000"
    end

    test "fractional values" do
      assert FastDecimal.to_string(~d"1.23") == "1.23"
      assert FastDecimal.to_string(~d"-1.23") == "-1.23"
      assert FastDecimal.to_string(~d"0.001") == "0.001"
      assert FastDecimal.to_string(~d"-0.001") == "-0.001"
    end

    test "leading zeros in fractional part" do
      assert FastDecimal.to_string(%FastDecimal{coef: 1, exp: -5}) == "0.00001"
      assert FastDecimal.to_string(%FastDecimal{coef: -1, exp: -5}) == "-0.00001"
    end

    test "preserves trailing zeros" do
      assert FastDecimal.to_string(~d"1.10") == "1.10"
      assert FastDecimal.to_string(~d"1.100") == "1.100"
    end

    test "positive exponent (multiplies)" do
      assert FastDecimal.to_string(%FastDecimal{coef: 12, exp: 3}) == "12000"
    end
  end

  describe "to_integer/1 and to_float/1" do
    test "to_integer of integer values" do
      assert FastDecimal.to_integer(~d"42") == 42
      assert FastDecimal.to_integer(~d"-100") == -100
      assert FastDecimal.to_integer(%FastDecimal{coef: 12, exp: 3}) == 12000
    end

    test "to_integer raises on fractional" do
      assert_raise ArgumentError, fn -> FastDecimal.to_integer(~d"1.5") end
    end

    test "to_float" do
      assert FastDecimal.to_float(~d"1.5") == 1.5
      assert FastDecimal.to_float(~d"-0.25") == -0.25
      assert FastDecimal.to_float(~d"42") == 42.0
    end
  end

  describe "normalize/1" do
    test "strips fractional trailing zeros" do
      assert FastDecimal.normalize(~d"1.10") == ~d"1.1"
      assert FastDecimal.normalize(~d"1.100") == ~d"1.1"
    end

    test "strips integer trailing zeros into a positive exponent" do
      # 100 normalizes to coef=1, exp=2 (still equal to 100)
      result = FastDecimal.normalize(~d"100")
      assert result == %FastDecimal{coef: 1, exp: 2}
      assert FastDecimal.equal?(result, ~d"100")
    end

    test "preserves zero" do
      assert FastDecimal.normalize(~d"0") == ~d"0"
      assert FastDecimal.normalize(~d"0.00") == ~d"0"
    end
  end

  describe "protocols" do
    test "Inspect produces sigil form (round-trippable)" do
      assert inspect(~d"1.23") == "~d\"1.23\""
      assert inspect(~d"-0.001") == "~d\"-0.001\""
    end

    test "String.Chars delegates to to_string" do
      assert "#{~d"1.23"}" == "1.23"
      assert "#{~d"-42"}" == "-42"
    end
  end

  describe "batch ops" do
    test "sum/1 of empty list" do
      assert FastDecimal.sum([]) == %FastDecimal{coef: 0, exp: 0}
    end

    test "sum/1 single element" do
      assert FastDecimal.sum([~d"1.23"]) == ~d"1.23"
    end

    test "sum/1 of small list" do
      assert FastDecimal.sum([~d"1.5", ~d"2.5", ~d"3"]) |> FastDecimal.equal?(~d"7.0")
    end

    test "sum/1 with mixed signs and exponents" do
      list = [~d"100", ~d"-50.5", ~d"0.001", ~d"49.499"]
      assert FastDecimal.sum(list) |> FastDecimal.equal?(~d"99")
    end

    test "sum/1 matches Enum.reduce" do
      list = for n <- 1..50, do: FastDecimal.new("#{n}.#{rem(n * 13, 100)}")
      reduce_result = Enum.reduce(list, FastDecimal.new(0), &FastDecimal.add/2)
      assert FastDecimal.equal?(FastDecimal.sum(list), reduce_result)
    end

    test "product/1 of empty list returns one (multiplicative identity)" do
      assert FastDecimal.product([]) == %FastDecimal{coef: 1, exp: 0}
    end

    test "product/1 single element" do
      assert FastDecimal.product([~d"1.23"]) == ~d"1.23"
    end

    test "product/1 of small list" do
      assert FastDecimal.product([~d"2", ~d"3", ~d"5"]) |> FastDecimal.equal?(~d"30")
    end

    test "product/1 with zero produces zero" do
      assert FastDecimal.product([~d"5", ~d"0", ~d"3"]) |> FastDecimal.equal?(~d"0")
    end
  end

  describe "bignum coefficients (overflow into BEAM bignum)" do
    test "very large add — value equality (representation may differ from Decimal)" do
      huge = String.duplicate("9", 30) <> "." <> String.duplicate("9", 10)
      result = FastDecimal.add(FastDecimal.new(huge), FastDecimal.new("0.0000000001"))

      decimal_result =
        Decimal.add(Decimal.new(huge), Decimal.new("0.0000000001"))
        |> Decimal.to_string(:normal)

      # Values are equal even if Decimal normalizes away trailing zeros while we don't.
      assert FastDecimal.equal?(result, FastDecimal.new(decimal_result))
    end

    test "very large mult is mathematically exact (no precision bound)" do
      # FastDecimal does exact arithmetic — no implicit precision context like Decimal has.
      # (10^15 - 1)^2 = 10^30 - 2*10^15 + 1 = 999999999999998000000000000001
      a = String.duplicate("9", 15)
      result = FastDecimal.mult(FastDecimal.new(a), FastDecimal.new(a))
      assert FastDecimal.to_string(result) == "999999999999998000000000000001"
    end
  end
end
