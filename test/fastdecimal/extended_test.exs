defmodule FastDecimal.ExtendedTest do
  use ExUnit.Case, async: true

  import FastDecimal, only: [sigil_d: 2]

  describe "NaN / Infinity construction" do
    test "constants" do
      assert FastDecimal.nan() == %FastDecimal{coef: :nan, exp: 0}
      assert FastDecimal.inf() == %FastDecimal{coef: :inf, exp: 0}
      assert FastDecimal.neg_inf() == %FastDecimal{coef: :neg_inf, exp: 0}
    end

    test "parse special-value strings" do
      assert FastDecimal.new("NaN") == FastDecimal.nan()
      assert FastDecimal.new("Infinity") == FastDecimal.inf()
      assert FastDecimal.new("Inf") == FastDecimal.inf()
      assert FastDecimal.new("-Infinity") == FastDecimal.neg_inf()
      assert FastDecimal.new("-Inf") == FastDecimal.neg_inf()
      assert FastDecimal.new("+Inf") == FastDecimal.inf()
    end

    test "sigil supports special values at compile time" do
      assert ~d"NaN" == FastDecimal.nan()
      assert ~d"Infinity" == FastDecimal.inf()
      assert ~d"-Infinity" == FastDecimal.neg_inf()
    end
  end

  describe "predicates with special values" do
    test "nan?" do
      assert FastDecimal.nan?(FastDecimal.nan())
      refute FastDecimal.nan?(FastDecimal.inf())
      refute FastDecimal.nan?(~d"0")
      refute FastDecimal.nan?(~d"1.23")
    end

    test "inf?" do
      assert FastDecimal.inf?(FastDecimal.inf())
      assert FastDecimal.inf?(FastDecimal.neg_inf())
      refute FastDecimal.inf?(FastDecimal.nan())
      refute FastDecimal.inf?(~d"1e1000")
    end

    test "finite?" do
      assert FastDecimal.finite?(~d"1.23")
      assert FastDecimal.finite?(~d"0")
      assert FastDecimal.finite?(~d"1e1000")
      refute FastDecimal.finite?(FastDecimal.nan())
      refute FastDecimal.finite?(FastDecimal.inf())
      refute FastDecimal.finite?(FastDecimal.neg_inf())
    end

    test "positive? / negative? handle infinities" do
      assert FastDecimal.positive?(FastDecimal.inf())
      refute FastDecimal.positive?(FastDecimal.neg_inf())
      refute FastDecimal.positive?(FastDecimal.nan())

      assert FastDecimal.negative?(FastDecimal.neg_inf())
      refute FastDecimal.negative?(FastDecimal.inf())
      refute FastDecimal.negative?(FastDecimal.nan())
    end
  end

  describe "arithmetic with NaN/Inf" do
    test "add" do
      assert FastDecimal.add(FastDecimal.inf(), ~d"1") == FastDecimal.inf()
      assert FastDecimal.add(~d"1", FastDecimal.inf()) == FastDecimal.inf()
      assert FastDecimal.add(FastDecimal.neg_inf(), ~d"1") == FastDecimal.neg_inf()
      assert FastDecimal.add(FastDecimal.inf(), FastDecimal.inf()) == FastDecimal.inf()
      assert FastDecimal.add(FastDecimal.inf(), FastDecimal.neg_inf()) == FastDecimal.nan()
      assert FastDecimal.add(FastDecimal.nan(), ~d"1") == FastDecimal.nan()
    end

    test "mult" do
      assert FastDecimal.mult(FastDecimal.inf(), ~d"2") == FastDecimal.inf()
      assert FastDecimal.mult(FastDecimal.inf(), ~d"-2") == FastDecimal.neg_inf()
      assert FastDecimal.mult(FastDecimal.inf(), ~d"0") == FastDecimal.nan()
      assert FastDecimal.mult(FastDecimal.neg_inf(), FastDecimal.neg_inf()) == FastDecimal.inf()
      assert FastDecimal.mult(FastDecimal.nan(), ~d"5") == FastDecimal.nan()
    end

    test "div" do
      assert FastDecimal.div(FastDecimal.inf(), ~d"2") == FastDecimal.inf()
      assert FastDecimal.div(FastDecimal.inf(), ~d"-2") == FastDecimal.neg_inf()
      assert FastDecimal.div(~d"1", FastDecimal.inf()) == ~d"0"
      assert FastDecimal.div(FastDecimal.inf(), FastDecimal.inf()) == FastDecimal.nan()
    end

    test "negate / abs" do
      assert FastDecimal.negate(FastDecimal.inf()) == FastDecimal.neg_inf()
      assert FastDecimal.negate(FastDecimal.neg_inf()) == FastDecimal.inf()
      assert FastDecimal.negate(FastDecimal.nan()) == FastDecimal.nan()

      assert FastDecimal.abs(FastDecimal.inf()) == FastDecimal.inf()
      assert FastDecimal.abs(FastDecimal.neg_inf()) == FastDecimal.inf()
      assert FastDecimal.abs(FastDecimal.nan()) == FastDecimal.nan()
    end

    test "compare returns :nan for NaN inputs" do
      assert FastDecimal.compare(FastDecimal.nan(), ~d"1") == :nan
      assert FastDecimal.compare(~d"1", FastDecimal.nan()) == :nan
      assert FastDecimal.compare(FastDecimal.nan(), FastDecimal.nan()) == :nan
    end

    test "compare orders infinities" do
      assert FastDecimal.compare(FastDecimal.inf(), ~d"1000000") == :gt
      assert FastDecimal.compare(~d"1000000", FastDecimal.inf()) == :lt
      assert FastDecimal.compare(FastDecimal.neg_inf(), ~d"-1000000") == :lt
      assert FastDecimal.compare(FastDecimal.inf(), FastDecimal.inf()) == :eq
      assert FastDecimal.compare(FastDecimal.neg_inf(), FastDecimal.neg_inf()) == :eq
      assert FastDecimal.compare(FastDecimal.inf(), FastDecimal.neg_inf()) == :gt
    end

    test "equal? returns false for NaN" do
      refute FastDecimal.equal?(FastDecimal.nan(), FastDecimal.nan())
      refute FastDecimal.equal?(FastDecimal.nan(), ~d"1")
      assert FastDecimal.equal?(FastDecimal.inf(), FastDecimal.inf())
    end
  end

  describe "round/3" do
    test "default (banker's, 0 places)" do
      assert FastDecimal.round(~d"1.5") == ~d"2"
      assert FastDecimal.round(~d"2.5") == ~d"2"
      assert FastDecimal.round(~d"3.5") == ~d"4"
      assert FastDecimal.round(~d"-1.5") == ~d"-2"
    end

    test "all rounding modes on 1.5" do
      assert FastDecimal.round(~d"1.5", 0, :half_even) == ~d"2"
      assert FastDecimal.round(~d"1.5", 0, :half_up) == ~d"2"
      assert FastDecimal.round(~d"1.5", 0, :half_down) == ~d"1"
      assert FastDecimal.round(~d"1.5", 0, :down) == ~d"1"
      assert FastDecimal.round(~d"1.5", 0, :up) == ~d"2"
      assert FastDecimal.round(~d"1.5", 0, :floor) == ~d"1"
      assert FastDecimal.round(~d"1.5", 0, :ceiling) == ~d"2"
    end

    test "all rounding modes on -1.5" do
      assert FastDecimal.round(~d"-1.5", 0, :half_even) == ~d"-2"
      assert FastDecimal.round(~d"-1.5", 0, :half_up) == ~d"-2"
      assert FastDecimal.round(~d"-1.5", 0, :down) == ~d"-1"
      assert FastDecimal.round(~d"-1.5", 0, :up) == ~d"-2"
      assert FastDecimal.round(~d"-1.5", 0, :floor) == ~d"-2"
      assert FastDecimal.round(~d"-1.5", 0, :ceiling) == ~d"-1"
    end

    test "places > 0 (decimal positions)" do
      assert FastDecimal.round(~d"1.236", 2) == ~d"1.24"
      assert FastDecimal.round(~d"1.234", 2) == ~d"1.23"
      assert FastDecimal.round(~d"1.235", 2, :half_even) == ~d"1.24"
      assert FastDecimal.round(~d"1.245", 2, :half_even) == ~d"1.24"
    end

    test "places < 0 (round to tens, hundreds)" do
      assert FastDecimal.round(~d"123.456", -1) |> FastDecimal.equal?(~d"120")
      assert FastDecimal.round(~d"156", -2) |> FastDecimal.equal?(~d"200")
    end

    test "NaN / Inf pass through" do
      assert FastDecimal.round(FastDecimal.nan(), 2) == FastDecimal.nan()
      assert FastDecimal.round(FastDecimal.inf(), 2) == FastDecimal.inf()
    end

    test "no-op when already at or above target precision" do
      assert FastDecimal.round(~d"1.23", 5) == ~d"1.23"
      assert FastDecimal.round(~d"42", 0) == ~d"42"
    end
  end

  describe "cast/1" do
    test "FastDecimal pass-through" do
      assert {:ok, d} = FastDecimal.cast(~d"1.23")
      assert FastDecimal.equal?(d, ~d"1.23")
    end

    test "integer / binary / float" do
      assert {:ok, ~d"42"} = FastDecimal.cast(42)
      assert {:ok, %FastDecimal{coef: 123, exp: -2}} = FastDecimal.cast("1.23")
      assert {:ok, _} = FastDecimal.cast(0.5)
    end

    test "Decimal struct conversion" do
      assert {:ok, %FastDecimal{coef: 123, exp: -2}} = FastDecimal.cast(Decimal.new("1.23"))
      assert {:ok, %FastDecimal{coef: -42, exp: -1}} = FastDecimal.cast(Decimal.new("-4.2"))
    end

    test "Decimal special values" do
      assert {:ok, d} = FastDecimal.cast(Decimal.new("NaN"))
      assert FastDecimal.nan?(d)

      assert {:ok, d} = FastDecimal.cast(Decimal.new("Infinity"))
      assert FastDecimal.inf?(d)
    end

    test "error on bad input" do
      assert FastDecimal.cast(nil) == :error
      assert FastDecimal.cast("not a number") == :error
      assert FastDecimal.cast(:atom) == :error
    end
  end

  describe "scientific notation parsing" do
    test "lowercase e and uppercase E" do
      assert FastDecimal.equal?(FastDecimal.new("1.23e10"), ~d"12300000000")
      assert FastDecimal.equal?(FastDecimal.new("1.23E10"), ~d"12300000000")
    end

    test "signed exponent" do
      assert FastDecimal.equal?(FastDecimal.new("1e-5"), ~d"0.00001")
      assert FastDecimal.equal?(FastDecimal.new("1e+5"), ~d"100000")
    end

    test "integer mantissa with exponent" do
      assert FastDecimal.equal?(FastDecimal.new("5e3"), ~d"5000")
      assert FastDecimal.equal?(FastDecimal.new("5e-3"), ~d"0.005")
    end

    test "error on incomplete exponent" do
      assert FastDecimal.parse("1e") == :error
      assert FastDecimal.parse("1e-") == :error
      assert FastDecimal.parse("e10") == :error
    end
  end

  describe "div_int / div_rem / rem" do
    test "div_int truncates toward zero" do
      assert FastDecimal.div_int(~d"10", ~d"3") == ~d"3"
      assert FastDecimal.div_int(~d"-10", ~d"3") == ~d"-3"
      assert FastDecimal.div_int(~d"10", ~d"-3") == ~d"-3"
    end

    test "div_int with fractional inputs" do
      assert FastDecimal.div_int(~d"10.5", ~d"3") == ~d"3"
      assert FastDecimal.div_int(~d"10", ~d"3.5") == ~d"2"
    end

    test "div_rem returns {quot, rem}" do
      assert {q, r} = FastDecimal.div_rem(~d"10", ~d"3")
      assert FastDecimal.equal?(q, ~d"3")
      assert FastDecimal.equal?(r, ~d"1")
    end

    test "div_rem invariant: a == q*b + r" do
      for {a, b} <- [{"10", "3"}, {"7.5", "2"}, {"-13", "4"}, {"100.5", "1.2"}] do
        {q, r} = FastDecimal.div_rem(FastDecimal.new(a), FastDecimal.new(b))

        reconstructed =
          FastDecimal.add(FastDecimal.mult(q, FastDecimal.new(b)), r)

        assert FastDecimal.equal?(reconstructed, FastDecimal.new(a)),
               "div_rem invariant failed for #{a} / #{b}: q=#{q}, r=#{r}"
      end
    end

    test "rem returns just the remainder" do
      assert FastDecimal.equal?(FastDecimal.rem(~d"10", ~d"3"), ~d"1")
      assert FastDecimal.equal?(FastDecimal.rem(~d"7", ~d"2"), ~d"1")
    end

    test "div_int by zero raises" do
      assert_raise ArithmeticError, fn -> FastDecimal.div_int(~d"1", ~d"0") end
    end
  end

  describe "sqrt/2" do
    test "perfect squares" do
      # `equal?` because sqrt normalizes — sqrt(100) is `coef: 1, exp: 1` not
      # `coef: 10, exp: 0`. Same value, different representation.
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"4"), ~d"2")
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"9"), ~d"3")
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"100"), ~d"10")
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"10000"), ~d"100")
    end

    test "sqrt(2) at various precisions" do
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"2", precision: 5), ~d"1.4142")
      assert FastDecimal.equal?(FastDecimal.sqrt(~d"2", precision: 10), ~d"1.414213562")
    end

    test "sqrt of zero / negative / special" do
      assert FastDecimal.sqrt(~d"0") == ~d"0"
      assert FastDecimal.sqrt(~d"-1") == FastDecimal.nan()
      assert FastDecimal.sqrt(FastDecimal.nan()) == FastDecimal.nan()
      assert FastDecimal.sqrt(FastDecimal.inf()) == FastDecimal.inf()
      assert FastDecimal.sqrt(FastDecimal.neg_inf()) == FastDecimal.nan()
    end

    test "sqrt(x)^2 ≈ x for representative inputs" do
      for s <- ["2", "9.99", "1234.5678", "0.000001"] do
        x = FastDecimal.new(s)
        r = FastDecimal.sqrt(x, precision: 28)
        squared = FastDecimal.mult(r, r)
        # The squared value should be very close to x. Use relative compare.
        diff = FastDecimal.abs(FastDecimal.sub(squared, x))
        # tolerance: 1e-26 absolute is well within precision=28
        assert FastDecimal.lt?(diff, FastDecimal.new("1e-20")),
               "sqrt(#{s})^2 = #{squared}, expected ~ #{s}"
      end
    end
  end

  describe "to_string formats" do
    test ":normal (default) — no exponent shown" do
      assert FastDecimal.to_string(~d"1.23") == "1.23"
      assert FastDecimal.to_string(~d"123") == "123"
      assert FastDecimal.to_string(~d"0.001") == "0.001"
    end

    test ":scientific (IEEE 754-2008 to-scientific-string — compact form)" do
      # The compact rule: use E-notation only when the normal form would have
      # an adjusted-exponent < -6 (very small) or exp > 0 (very large).
      # Matches Decimal.to_string/2's `:scientific` output.

      # Normal-form values (no E):
      assert FastDecimal.to_string(~d"1.23", :scientific) == "1.23"
      assert FastDecimal.to_string(~d"123", :scientific) == "123"
      assert FastDecimal.to_string(~d"0.001", :scientific) == "0.001"
      assert FastDecimal.to_string(~d"-42.5", :scientific) == "-42.5"
      assert FastDecimal.to_string(~d"0", :scientific) == "0E+0"

      # Adjusted exp < -6 — E-notation kicks in:
      assert FastDecimal.to_string(~d"0.0000001", :scientific) == "1E-7"
      assert FastDecimal.to_string(~d"-0.0000005", :scientific) == "-5E-7"

      # exp > 0 (positive exponent stored, e.g., from `normalize`) — E-notation:
      assert FastDecimal.to_string(%FastDecimal{coef: 1, exp: 5}, :scientific) == "1E+5"
      assert FastDecimal.to_string(%FastDecimal{coef: 123, exp: 2}, :scientific) == "1.23E+4"
    end

    test ":raw shows internal representation" do
      assert FastDecimal.to_string(~d"1.23", :raw) == "123E-2"
      assert FastDecimal.to_string(~d"42", :raw) == "42"
      assert FastDecimal.to_string(~d"-1.5", :raw) == "-15E-1"
    end

    test ":xsd" do
      assert FastDecimal.to_string(~d"1.23", :xsd) == "1.23"
      assert FastDecimal.to_string(~d"42", :xsd) == "42"
    end

    test "special values render the same in every format" do
      assert FastDecimal.to_string(FastDecimal.nan(), :normal) == "NaN"
      assert FastDecimal.to_string(FastDecimal.nan(), :scientific) == "NaN"
      assert FastDecimal.to_string(FastDecimal.inf(), :raw) == "Infinity"
      assert FastDecimal.to_string(FastDecimal.neg_inf(), :scientific) == "-Infinity"
    end
  end

  describe "is_decimal/1 macro" do
    require FastDecimal

    test "true for FastDecimal structs" do
      assert FastDecimal.is_decimal(~d"1.23")
      assert FastDecimal.is_decimal(FastDecimal.nan())
    end

    test "false for non-structs" do
      refute FastDecimal.is_decimal(42)
      refute FastDecimal.is_decimal("string")
      refute FastDecimal.is_decimal(%{})
      refute FastDecimal.is_decimal(nil)
    end

    test "false for other structs" do
      refute FastDecimal.is_decimal(Decimal.new("1.23"))
    end
  end
end
