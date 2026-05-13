defmodule FastDecimal.CorrectnessTest do
  @moduledoc """
  Two kinds of correctness verification:

  1. **Mathematical-truth tests** — for each operation, pin down inputs to
     known exact results that have been verified manually. FastDecimal must
     produce these values. These tests don't reference Decimal at all; they
     are the floor of "are we computing arithmetic correctly?"

  2. **Differential tests vs Decimal** — for each operation, run a matrix of
     diverse input pairs through both FastDecimal and Decimal and assert
     semantic equality. Catches any drift from Decimal's behavior on inputs
     where the two libraries SHOULD agree.

  ## When the two libraries legitimately diverge

  FastDecimal does *exact arithmetic* (no implicit precision context).
  Decimal rounds results to its Context.precision (28 by default). So for
  inputs whose true result has >28 significant digits, Decimal will round
  and FastDecimal won't. That's a documented design difference, not a bug.

  The differential tests below avoid that divergence by constraining input
  ranges so the result stays within 28 sig figs. Tests that compare exact
  numeric outputs use FastDecimal.equal? after parsing the Decimal output
  back through FastDecimal.new — i.e., we compare numeric values, not
  struct representations.
  """

  use ExUnit.Case, async: true

  import FastDecimal, only: [sigil_d: 2]

  # ---- Fixtures ----------------------------------------------------------

  @small_values [
    "0",
    "1",
    "-1",
    "2",
    "-2",
    "0.1",
    "-0.1",
    "0.5",
    "-0.5",
    "1.23",
    "-1.23",
    "1.10",
    "-1.10",
    "9.99",
    "-9.99"
  ]

  @medium_values [
    "10",
    "-10",
    "100",
    "-100",
    "100.5",
    "-100.5",
    "1234.56789",
    "-1234.56789",
    "0.0001",
    "-0.0001",
    "9999.9999",
    "-9999.9999",
    "100000",
    "-100000"
  ]

  @large_values [
    "1000000",
    "-1000000",
    "1234567890.123456789",
    "-1234567890.123456789",
    "9999999999.9999999999"
  ]

  @zero_forms ["0", "0.0", "0.00", "-0", "-0.0"]

  @all_values @small_values ++ @medium_values ++ @large_values
  @nonzero_values Enum.reject(@all_values, &(FastDecimal.new(&1) |> FastDecimal.zero?()))

  # ---- Helpers -----------------------------------------------------------

  defp via_decimal(op_fn, args) when is_list(args) do
    # Convert Decimal result back to FastDecimal for value comparison.
    {:ok, fd} = apply(op_fn, args) |> FastDecimal.cast()
    fd
  end

  defp assert_equal_values(actual, expected, ctx) do
    if !FastDecimal.equal?(actual, expected) do
      flunk(
        "Value mismatch#{if ctx == "", do: "", else: " (#{ctx})"}\n" <>
          "  actual:   #{FastDecimal.to_string(actual)}\n" <>
          "  expected: #{FastDecimal.to_string(expected)}"
      )
    end
  end

  # ====================================================================
  # ADD
  # ====================================================================

  describe "add: known exact mathematical results" do
    test "1.23 + 4.567 == 5.797" do
      assert FastDecimal.add(~d"1.23", ~d"4.567") |> FastDecimal.equal?(~d"5.797")
    end

    test "0.1 + 0.2 == 0.3 (no IEEE 754 float error)" do
      assert FastDecimal.add(~d"0.1", ~d"0.2") |> FastDecimal.equal?(~d"0.3")
    end

    test "additive inverse: a + (-a) == 0" do
      for s <- @all_values do
        a = FastDecimal.new(s)

        assert FastDecimal.add(a, FastDecimal.negate(a)) |> FastDecimal.equal?(~d"0"),
               "for #{s}, a + -a should be 0"
      end
    end

    test "additive identity: a + 0 == a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.add(a, ~d"0") |> FastDecimal.equal?(a)
        assert FastDecimal.add(~d"0", a) |> FastDecimal.equal?(a)
      end
    end

    test "specific multi-digit cases" do
      assert FastDecimal.add(~d"100", ~d"0.001") |> FastDecimal.equal?(~d"100.001")
      assert FastDecimal.add(~d"-5.5", ~d"5.5") |> FastDecimal.equal?(~d"0")
      assert FastDecimal.add(~d"999.999", ~d"0.001") |> FastDecimal.equal?(~d"1000")
      assert FastDecimal.add(~d"1234567.89", ~d"0.11") |> FastDecimal.equal?(~d"1234568")
    end
  end

  describe "add: differential vs Decimal" do
    test "every pair of values produces the same result" do
      for a <- @all_values, b <- @all_values do
        fd = FastDecimal.add(FastDecimal.new(a), FastDecimal.new(b))
        dec = via_decimal(&Decimal.add/2, [Decimal.new(a), Decimal.new(b)])
        assert_equal_values(fd, dec, "add(#{a}, #{b})")
      end
    end
  end

  # ====================================================================
  # SUB
  # ====================================================================

  describe "sub: known results" do
    test "10 - 3.14 == 6.86" do
      assert FastDecimal.sub(~d"10", ~d"3.14") |> FastDecimal.equal?(~d"6.86")
    end

    test "a - a == 0 for any a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.sub(a, a) |> FastDecimal.equal?(~d"0")
      end
    end

    test "a - 0 == a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.sub(a, ~d"0") |> FastDecimal.equal?(a)
      end
    end

    test "1 - 0.000001 == 0.999999" do
      assert FastDecimal.sub(~d"1", ~d"0.000001") |> FastDecimal.equal?(~d"0.999999")
    end
  end

  describe "sub: differential vs Decimal" do
    test "every pair of values produces the same result" do
      for a <- @all_values, b <- @all_values do
        fd = FastDecimal.sub(FastDecimal.new(a), FastDecimal.new(b))
        dec = via_decimal(&Decimal.sub/2, [Decimal.new(a), Decimal.new(b)])
        assert_equal_values(fd, dec, "sub(#{a}, #{b})")
      end
    end
  end

  # ====================================================================
  # MULT
  # ====================================================================

  describe "mult: known results" do
    test "specific exact products" do
      assert FastDecimal.mult(~d"1.5", ~d"2") |> FastDecimal.equal?(~d"3")
      assert FastDecimal.mult(~d"0.1", ~d"0.2") |> FastDecimal.equal?(~d"0.02")
      assert FastDecimal.mult(~d"0.5", ~d"0.5") |> FastDecimal.equal?(~d"0.25")
      assert FastDecimal.mult(~d"-2", ~d"3") |> FastDecimal.equal?(~d"-6")
      assert FastDecimal.mult(~d"-2", ~d"-3") |> FastDecimal.equal?(~d"6")
      assert FastDecimal.mult(~d"100", ~d"100") |> FastDecimal.equal?(~d"10000")
      assert FastDecimal.mult(~d"1.23", ~d"4.567") |> FastDecimal.equal?(~d"5.61741")
    end

    test "multiplicative identity: a * 1 == a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.mult(a, ~d"1") |> FastDecimal.equal?(a)
        assert FastDecimal.mult(~d"1", a) |> FastDecimal.equal?(a)
      end
    end

    test "annihilator: a * 0 == 0" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.mult(a, ~d"0") |> FastDecimal.equal?(~d"0")
      end
    end

    test "(-1) * a == -a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.mult(~d"-1", a) |> FastDecimal.equal?(FastDecimal.negate(a))
      end
    end
  end

  describe "mult: differential vs Decimal" do
    test "every pair from small/medium produces same result (large skipped — Decimal rounds)" do
      smaller = @small_values ++ @medium_values

      for a <- smaller, b <- smaller do
        fd = FastDecimal.mult(FastDecimal.new(a), FastDecimal.new(b))
        dec = via_decimal(&Decimal.mult/2, [Decimal.new(a), Decimal.new(b)])
        assert_equal_values(fd, dec, "mult(#{a}, #{b})")
      end
    end
  end

  # ====================================================================
  # DIV
  # ====================================================================

  describe "div: known exact (terminating) results" do
    test "1 / 2 == 0.5" do
      result = FastDecimal.div(~d"1", ~d"2", precision: 28)
      assert FastDecimal.equal?(result, ~d"0.5")
    end

    test "1 / 4 == 0.25" do
      result = FastDecimal.div(~d"1", ~d"4", precision: 28)
      assert FastDecimal.equal?(result, ~d"0.25")
    end

    test "10 / 4 == 2.5" do
      result = FastDecimal.div(~d"10", ~d"4", precision: 28)
      assert FastDecimal.equal?(result, ~d"2.5")
    end

    test "100 / 25 == 4" do
      result = FastDecimal.div(~d"100", ~d"25", precision: 28)
      assert FastDecimal.equal?(result, ~d"4")
    end
  end

  describe "div: non-terminating cases with known truncated values" do
    test "1 / 3 at precision 5 == 0.33333 (half_even)" do
      result = FastDecimal.div(~d"1", ~d"3", precision: 5)
      assert FastDecimal.equal?(result, ~d"0.33333")
    end

    test "2 / 3 at precision 5 == 0.66667 (half_even rounds up)" do
      result = FastDecimal.div(~d"2", ~d"3", precision: 5)
      assert FastDecimal.equal?(result, ~d"0.66667")
    end

    test "1 / 7 at precision 5 == 0.14286" do
      result = FastDecimal.div(~d"1", ~d"7", precision: 5)
      assert FastDecimal.equal?(result, ~d"0.14286")
    end

    test "10 / 3 at precision 28 has 27 trailing 3s" do
      result = FastDecimal.div(~d"10", ~d"3", precision: 28)
      assert FastDecimal.to_string(result) == "3.333333333333333333333333333"
    end
  end

  describe "div: by zero raises" do
    test "any / 0 raises ArithmeticError" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert_raise ArithmeticError, fn -> FastDecimal.div(a, ~d"0") end
      end
    end
  end

  describe "div: identity" do
    test "a / 1 == a" do
      for s <- @all_values do
        a = FastDecimal.new(s)

        assert FastDecimal.div(a, ~d"1", precision: 28) |> FastDecimal.equal?(a),
               "a / 1 should equal a, for a = #{s}"
      end
    end

    test "a / a == 1 for nonzero a" do
      for s <- @nonzero_values do
        a = FastDecimal.new(s)

        assert FastDecimal.div(a, a, precision: 28) |> FastDecimal.equal?(~d"1"),
               "a / a should equal 1, for a = #{s}"
      end
    end
  end

  # ====================================================================
  # DIV_INT, DIV_REM, REM
  # ====================================================================

  describe "div_int: known results (truncates toward zero)" do
    test "specific cases" do
      assert FastDecimal.div_int(~d"10", ~d"3") |> FastDecimal.equal?(~d"3")
      assert FastDecimal.div_int(~d"10", ~d"-3") |> FastDecimal.equal?(~d"-3")
      assert FastDecimal.div_int(~d"-10", ~d"3") |> FastDecimal.equal?(~d"-3")
      assert FastDecimal.div_int(~d"-10", ~d"-3") |> FastDecimal.equal?(~d"3")
      assert FastDecimal.div_int(~d"100", ~d"4") |> FastDecimal.equal?(~d"25")
      assert FastDecimal.div_int(~d"7", ~d"2") |> FastDecimal.equal?(~d"3")
    end

    test "fractional dividends" do
      assert FastDecimal.div_int(~d"10.5", ~d"3") |> FastDecimal.equal?(~d"3")
      assert FastDecimal.div_int(~d"10.999", ~d"3") |> FastDecimal.equal?(~d"3")
    end
  end

  describe "div_rem: invariant a == q*b + r" do
    test "across many input pairs" do
      for a <- @small_values ++ @medium_values, b <- @nonzero_values do
        a_fd = FastDecimal.new(a)
        b_fd = FastDecimal.new(b)
        {q, r} = FastDecimal.div_rem(a_fd, b_fd)
        reconstructed = FastDecimal.add(FastDecimal.mult(q, b_fd), r)

        assert FastDecimal.equal?(reconstructed, a_fd),
               "div_rem invariant failed: #{a} / #{b}, q=#{q}, r=#{r}"
      end
    end
  end

  # ====================================================================
  # NEGATE, ABS
  # ====================================================================

  describe "negate" do
    test "negate(0) == 0" do
      assert FastDecimal.negate(~d"0") |> FastDecimal.equal?(~d"0")
    end

    test "involutive: negate(negate(a)) == a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.negate(FastDecimal.negate(a)) |> FastDecimal.equal?(a)
      end
    end

    test "matches Decimal.negate for all values" do
      for s <- @all_values do
        fd = FastDecimal.negate(FastDecimal.new(s))
        dec = via_decimal(&Decimal.negate/1, [Decimal.new(s)])
        assert_equal_values(fd, dec, "negate(#{s})")
      end
    end
  end

  describe "abs" do
    test "abs is never negative" do
      for s <- @all_values do
        result = FastDecimal.abs(FastDecimal.new(s))
        refute FastDecimal.negative?(result), "abs(#{s}) should not be negative"
      end
    end

    test "idempotent: abs(abs(a)) == abs(a)" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.abs(FastDecimal.abs(a)) |> FastDecimal.equal?(FastDecimal.abs(a))
      end
    end

    test "matches Decimal.abs for all values" do
      for s <- @all_values do
        fd = FastDecimal.abs(FastDecimal.new(s))
        dec = via_decimal(&Decimal.abs/1, [Decimal.new(s)])
        assert_equal_values(fd, dec, "abs(#{s})")
      end
    end
  end

  # ====================================================================
  # COMPARE / EQUAL? / LT? / GT? / MIN / MAX
  # ====================================================================

  describe "compare: reflexivity" do
    test "compare(a, a) == :eq for any a" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        assert FastDecimal.compare(a, a) == :eq
      end
    end
  end

  describe "compare: antisymmetry vs Decimal" do
    test "FastDecimal.compare agrees with Decimal.compare for all pairs" do
      for a <- @all_values, b <- @all_values do
        fd = FastDecimal.compare(FastDecimal.new(a), FastDecimal.new(b))
        dec = Decimal.compare(Decimal.new(a), Decimal.new(b))

        assert fd == dec,
               "compare(#{a}, #{b}): FastDecimal=#{fd}, Decimal=#{dec}"
      end
    end
  end

  describe "compare: 1.10 == 1.1 (different representations, same value)" do
    test "value-equality not struct-equality" do
      assert FastDecimal.compare(~d"1.10", ~d"1.1") == :eq
      assert FastDecimal.compare(~d"100.000", ~d"100") == :eq
      assert FastDecimal.compare(~d"-0.50", ~d"-0.5") == :eq
    end
  end

  describe "min / max" do
    test "min/max agree with Decimal across pairs" do
      for a <- @all_values, b <- @all_values do
        a_fd = FastDecimal.new(a)
        b_fd = FastDecimal.new(b)
        a_dec = Decimal.new(a)
        b_dec = Decimal.new(b)

        fd_min = FastDecimal.min(a_fd, b_fd)
        dec_min = via_decimal(&Decimal.min/2, [a_dec, b_dec])
        assert_equal_values(fd_min, dec_min, "min(#{a}, #{b})")

        fd_max = FastDecimal.max(a_fd, b_fd)
        dec_max = via_decimal(&Decimal.max/2, [a_dec, b_dec])
        assert_equal_values(fd_max, dec_max, "max(#{a}, #{b})")
      end
    end
  end

  # ====================================================================
  # PREDICATES
  # ====================================================================

  describe "zero? / positive? / negative? agree with Decimal" do
    # Note: Decimal v2.4.1 doesn't expose stand-alone predicates; we derive
    # the equivalent semantics via `Decimal.compare/2` against zero.
    test "FastDecimal predicates match the Decimal compare-based equivalents" do
      zero_dec = Decimal.new(0)

      for s <- @all_values ++ @zero_forms do
        fd = FastDecimal.new(s)
        dec = Decimal.new(s)

        dec_is_zero = Decimal.compare(dec, zero_dec) == :eq
        dec_is_positive = Decimal.compare(dec, zero_dec) == :gt
        dec_is_negative = Decimal.compare(dec, zero_dec) == :lt

        assert FastDecimal.zero?(fd) == dec_is_zero, "zero?(#{s})"
        assert FastDecimal.positive?(fd) == dec_is_positive, "positive?(#{s})"
        assert FastDecimal.negative?(fd) == dec_is_negative, "negative?(#{s})"
      end
    end
  end

  describe "predicates with NaN/Inf" do
    test "nan?, inf?, finite?" do
      assert FastDecimal.nan?(FastDecimal.nan())
      refute FastDecimal.nan?(~d"1.23")
      refute FastDecimal.nan?(FastDecimal.inf())

      assert FastDecimal.inf?(FastDecimal.inf())
      assert FastDecimal.inf?(FastDecimal.neg_inf())
      refute FastDecimal.inf?(FastDecimal.nan())
      refute FastDecimal.inf?(~d"1e1000")

      assert FastDecimal.finite?(~d"1.23")
      refute FastDecimal.finite?(FastDecimal.nan())
      refute FastDecimal.finite?(FastDecimal.inf())
    end
  end

  # ====================================================================
  # ROUND
  # ====================================================================

  describe "round: known exact results for each mode" do
    test "1.5 across all 7 modes" do
      assert FastDecimal.round(~d"1.5", 0, :half_even) |> FastDecimal.equal?(~d"2")
      assert FastDecimal.round(~d"1.5", 0, :half_up) |> FastDecimal.equal?(~d"2")
      assert FastDecimal.round(~d"1.5", 0, :half_down) |> FastDecimal.equal?(~d"1")
      assert FastDecimal.round(~d"1.5", 0, :down) |> FastDecimal.equal?(~d"1")
      assert FastDecimal.round(~d"1.5", 0, :up) |> FastDecimal.equal?(~d"2")
      assert FastDecimal.round(~d"1.5", 0, :floor) |> FastDecimal.equal?(~d"1")
      assert FastDecimal.round(~d"1.5", 0, :ceiling) |> FastDecimal.equal?(~d"2")
    end

    test "2.5 across all modes (banker's rounds to even)" do
      assert FastDecimal.round(~d"2.5", 0, :half_even) |> FastDecimal.equal?(~d"2")
      assert FastDecimal.round(~d"2.5", 0, :half_up) |> FastDecimal.equal?(~d"3")
    end

    test "negative -1.5 across modes" do
      assert FastDecimal.round(~d"-1.5", 0, :half_even) |> FastDecimal.equal?(~d"-2")
      assert FastDecimal.round(~d"-1.5", 0, :half_up) |> FastDecimal.equal?(~d"-2")
      assert FastDecimal.round(~d"-1.5", 0, :half_down) |> FastDecimal.equal?(~d"-1")
      assert FastDecimal.round(~d"-1.5", 0, :down) |> FastDecimal.equal?(~d"-1")
      assert FastDecimal.round(~d"-1.5", 0, :up) |> FastDecimal.equal?(~d"-2")
      assert FastDecimal.round(~d"-1.5", 0, :floor) |> FastDecimal.equal?(~d"-2")
      assert FastDecimal.round(~d"-1.5", 0, :ceiling) |> FastDecimal.equal?(~d"-1")
    end
  end

  describe "round: differential vs Decimal across all modes" do
    test "agrees on diverse inputs" do
      values = ["1.5", "2.5", "1.235", "1.245", "-1.5", "-2.5", "1.234", "99.99", "0.5"]
      modes = [:half_even, :half_up, :half_down, :down, :up, :floor, :ceiling]

      for v <- values, places <- [0, 1, 2, 3], mode <- modes do
        fd = FastDecimal.round(FastDecimal.new(v), places, mode)
        dec = via_decimal(&Decimal.round/3, [Decimal.new(v), places, mode])

        assert_equal_values(fd, dec, "round(#{v}, #{places}, #{mode})")
      end
    end
  end

  # ====================================================================
  # SQRT
  # ====================================================================

  describe "sqrt: exact for perfect squares" do
    test "perfect squares produce exact integer results" do
      cases = [
        {"0", "0"},
        {"1", "1"},
        {"4", "2"},
        {"9", "3"},
        {"16", "4"},
        {"100", "10"},
        {"10000", "100"},
        {"0.25", "0.5"},
        {"0.04", "0.2"},
        {"6.25", "2.5"}
      ]

      for {input, expected} <- cases do
        result = FastDecimal.sqrt(FastDecimal.new(input))

        assert FastDecimal.equal?(result, FastDecimal.new(expected)),
               "sqrt(#{input}): got #{result}, expected #{expected}"
      end
    end
  end

  describe "sqrt: approximate for non-squares (high precision)" do
    test "sqrt(2) at precision 28 (matches well-known constant)" do
      result = FastDecimal.sqrt(~d"2", precision: 28)
      # √2 = 1.4142135623730950488016887242...
      expected_prefix = "1.41421356237309504880168872"
      assert String.starts_with?(FastDecimal.to_string(result), expected_prefix)
    end

    test "sqrt(x)^2 ≈ x" do
      for s <- @nonzero_values, !String.starts_with?(s, "-") do
        x = FastDecimal.new(s)
        r = FastDecimal.sqrt(x, precision: 30)
        squared = FastDecimal.mult(r, r)
        diff = FastDecimal.abs(FastDecimal.sub(squared, x))
        tol = FastDecimal.max(FastDecimal.mult(FastDecimal.abs(x), ~d"1e-25"), ~d"1e-25")

        assert FastDecimal.compare(diff, tol) in [:lt, :eq],
               "sqrt(#{s})^2 too far from #{s}: diff=#{diff}"
      end
    end
  end

  describe "sqrt: special values" do
    test "sqrt(0) == 0" do
      assert FastDecimal.sqrt(~d"0") |> FastDecimal.equal?(~d"0")
    end

    test "sqrt(negative) == NaN" do
      for s <- ["-1", "-0.5", "-1234.5"] do
        assert FastDecimal.nan?(FastDecimal.sqrt(FastDecimal.new(s)))
      end
    end

    test "sqrt(NaN) == NaN, sqrt(Inf) == Inf, sqrt(-Inf) == NaN" do
      assert FastDecimal.nan?(FastDecimal.sqrt(FastDecimal.nan()))
      assert FastDecimal.inf?(FastDecimal.sqrt(FastDecimal.inf()))
      assert FastDecimal.nan?(FastDecimal.sqrt(FastDecimal.neg_inf()))
    end
  end

  # ====================================================================
  # NORMALIZE
  # ====================================================================

  describe "normalize: known results" do
    test "strips trailing zeros, preserves value" do
      assert FastDecimal.normalize(~d"1.10") == ~d"1.1"
      assert FastDecimal.normalize(~d"1.100") == ~d"1.1"
      assert FastDecimal.normalize(~d"0.0") == ~d"0"
    end

    test "100 becomes coef=1, exp=2" do
      result = FastDecimal.normalize(~d"100")
      assert result == %FastDecimal{coef: 1, exp: 2}
      assert FastDecimal.equal?(result, ~d"100")
    end
  end

  describe "normalize: invariants" do
    test "always preserves value" do
      for s <- @all_values do
        a = FastDecimal.new(s)

        assert FastDecimal.equal?(FastDecimal.normalize(a), a),
               "normalize changed value of #{s}"
      end
    end

    test "idempotent" do
      for s <- @all_values do
        a = FastDecimal.new(s)
        once = FastDecimal.normalize(a)
        twice = FastDecimal.normalize(once)
        assert once == twice, "normalize not idempotent for #{s}"
      end
    end
  end

  # ====================================================================
  # PARSE / NEW
  # ====================================================================

  describe "parse: matches Decimal.new for valid inputs" do
    test "all forms produce equivalent values" do
      cases = [
        "0",
        "1",
        "-1",
        "1.23",
        "-1.23",
        "+42",
        ".5",
        "5.",
        "0.0001",
        "1234567890.123",
        "1e10",
        "1.23e-5",
        "-1e+5",
        "100",
        "1000.000"
      ]

      for s <- cases do
        fd = FastDecimal.new(s)
        dec = via_decimal(&Decimal.new/1, [s])
        assert_equal_values(fd, dec, "new(#{inspect(s)})")
      end
    end

    test "special-value strings" do
      assert FastDecimal.equal?(FastDecimal.new("NaN"), FastDecimal.nan()) == false
      # NaN never equals anything per IEEE — verify with nan? predicate:
      assert FastDecimal.nan?(FastDecimal.new("NaN"))
      assert FastDecimal.inf?(FastDecimal.new("Infinity"))
      assert FastDecimal.inf?(FastDecimal.new("-Infinity"))
      assert FastDecimal.negative?(FastDecimal.new("-Infinity"))
    end
  end

  # ====================================================================
  # TO_STRING
  # ====================================================================

  describe "to_string: known exact outputs (:normal)" do
    test "specific cases" do
      cases = [
        {"0", "0"},
        {"1.23", "1.23"},
        {"-1.23", "-1.23"},
        {"100", "100"},
        {"0.001", "0.001"},
        {"-0.001", "-0.001"},
        {"1000000", "1000000"},
        {"1.10", "1.10"}
      ]

      for {input, expected} <- cases do
        assert FastDecimal.to_string(FastDecimal.new(input)) == expected,
               "to_string(#{input})"
      end
    end
  end

  describe "to_string: matches Decimal.to_string(:normal) across input set" do
    test "every value round-trips identically" do
      for s <- @all_values do
        fd_str = FastDecimal.to_string(FastDecimal.new(s))
        dec_str = Decimal.to_string(Decimal.new(s), :normal)

        # Both libraries should produce the same canonical normal form for
        # the same input.
        assert fd_str == dec_str,
               "to_string mismatch for #{inspect(s)}: FastDecimal=#{inspect(fd_str)}, Decimal=#{inspect(dec_str)}"
      end
    end
  end

  describe "to_string: round-trip integrity" do
    test ":normal format" do
      for s <- @all_values do
        d = FastDecimal.new(s)

        assert FastDecimal.equal?(FastDecimal.new(FastDecimal.to_string(d)), d),
               "normal-form round-trip failed for #{s}"
      end
    end

    test ":scientific format" do
      for s <- @all_values do
        d = FastDecimal.new(s)
        sci = FastDecimal.to_string(d, :scientific)

        assert FastDecimal.equal?(FastDecimal.new(sci), d),
               "scientific round-trip failed for #{s}: #{inspect(sci)}"
      end
    end

    test ":raw format" do
      for s <- @all_values do
        d = FastDecimal.new(s)
        raw = FastDecimal.to_string(d, :raw)

        assert FastDecimal.equal?(FastDecimal.new(raw), d),
               "raw round-trip failed for #{s}: #{inspect(raw)}"
      end
    end
  end

  # ====================================================================
  # SUM / PRODUCT
  # ====================================================================

  describe "sum: matches Enum.reduce(&add/2)" do
    test "various list sizes" do
      for n <- [1, 2, 5, 10, 50, 100] do
        list = for i <- 1..n, do: FastDecimal.new("#{i}.#{rem(i * 13, 100)}")
        sum_fn = FastDecimal.sum(list)
        sum_reduce = Enum.reduce(list, FastDecimal.new(0), &FastDecimal.add/2)

        assert FastDecimal.equal?(sum_fn, sum_reduce),
               "sum/1 diverged from reduce at n=#{n}"
      end
    end

    test "sum of [1..N] == N*(N+1)/2" do
      for n <- [10, 50, 100] do
        list = for i <- 1..n, do: FastDecimal.new(i)
        result = FastDecimal.sum(list)
        expected = FastDecimal.new(div(n * (n + 1), 2))
        assert FastDecimal.equal?(result, expected)
      end
    end
  end

  describe "product: known cases" do
    test "[2,3,5,7] == 210" do
      assert FastDecimal.product([~d"2", ~d"3", ~d"5", ~d"7"]) |> FastDecimal.equal?(~d"210")
    end

    test "empty list == 1 (multiplicative identity)" do
      assert FastDecimal.product([]) == ~d"1"
    end

    test "any zero makes the result zero" do
      assert FastDecimal.product([~d"5", ~d"0", ~d"3"]) |> FastDecimal.equal?(~d"0")
    end
  end

  # ====================================================================
  # NaN / Inf semantic propagation
  # ====================================================================

  describe "NaN propagation: every op with NaN returns NaN" do
    test "binary ops with NaN as either operand" do
      nan = FastDecimal.nan()

      for s <- ~w(0 1 -1 1.5 1000000) do
        x = FastDecimal.new(s)

        assert FastDecimal.nan?(FastDecimal.add(nan, x))
        assert FastDecimal.nan?(FastDecimal.add(x, nan))
        assert FastDecimal.nan?(FastDecimal.sub(nan, x))
        assert FastDecimal.nan?(FastDecimal.mult(nan, x))
        assert FastDecimal.nan?(FastDecimal.mult(x, nan))
        assert FastDecimal.compare(nan, x) == :nan
        assert FastDecimal.compare(x, nan) == :nan
      end
    end
  end

  describe "Infinity semantics" do
    test "inf + finite, inf - finite, inf * positive, inf * negative" do
      inf = FastDecimal.inf()
      neg_inf = FastDecimal.neg_inf()

      assert FastDecimal.equal?(FastDecimal.add(inf, ~d"1"), inf)
      assert FastDecimal.equal?(FastDecimal.add(neg_inf, ~d"-1"), neg_inf)
      assert FastDecimal.nan?(FastDecimal.add(inf, neg_inf))

      assert FastDecimal.equal?(FastDecimal.mult(inf, ~d"2"), inf)
      assert FastDecimal.equal?(FastDecimal.mult(inf, ~d"-2"), neg_inf)
      assert FastDecimal.nan?(FastDecimal.mult(inf, ~d"0"))
    end
  end

  # ====================================================================
  # TO_INTEGER / TO_FLOAT
  # ====================================================================

  describe "to_integer" do
    test "exact integer values" do
      assert FastDecimal.to_integer(~d"0") == 0
      assert FastDecimal.to_integer(~d"42") == 42
      assert FastDecimal.to_integer(~d"-100") == -100
      assert FastDecimal.to_integer(~d"1000000") == 1_000_000
    end

    test "fractional values raise" do
      assert_raise ArgumentError, fn -> FastDecimal.to_integer(~d"1.5") end
      assert_raise ArgumentError, fn -> FastDecimal.to_integer(~d"0.1") end
    end

    test "values that *look* fractional but are exact integers" do
      # 1.0 is an integer value, just stored with exp=-1
      d = ~d"1.0"
      assert FastDecimal.to_integer(d) == 1

      d = ~d"100.000"
      assert FastDecimal.to_integer(d) == 100
    end
  end

  describe "to_float" do
    test "matches Float.parse on the to_string output" do
      for s <- @small_values ++ @medium_values do
        d = FastDecimal.new(s)
        f = FastDecimal.to_float(d)
        {expected, ""} = Float.parse(s)
        # Allow tiny float rounding error
        assert_in_delta(f, expected, abs(expected) * 1.0e-10 + 1.0e-15, "to_float(#{s})")
      end
    end
  end
end
