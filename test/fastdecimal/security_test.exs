defmodule FastDecimal.SecurityTest do
  @moduledoc """
  Regression tests for **CVE-2026-32686-class exponent-amplification DoS**.

  Background: compact decimal inputs like `"1e1000000000"` represent values
  whose materialization would allocate gigabytes — running `to_string` or
  aligning operands for `add/sub` on such a value would OOM the BEAM or run
  for many seconds. `decimal` mitigated this in v2.4.0 with sticky-bit
  precision-bounded scaling; FastDecimal mitigates via three layers of
  hard bounds (see `lib/fastdecimal.ex` constants and
  `lib/fastdecimal/parser.ex`).

  These tests verify each layer holds.
  """

  use ExUnit.Case, async: true

  describe "parser layer: reject explicit-exponent DoS inputs" do
    test "rejects exponents > 65,535" do
      assert :error = FastDecimal.parse("1e65536")
      assert :error = FastDecimal.parse("1e100000")
      assert :error = FastDecimal.parse("1e1000000000")
    end

    test "rejects very negative exponents" do
      assert :error = FastDecimal.parse("1e-65536")
      assert :error = FastDecimal.parse("1e-1000000")
    end

    test "accepts exponents at the boundary" do
      assert {:ok, %FastDecimal{coef: 1, exp: 65535}} = FastDecimal.parse("1e65535")
      assert {:ok, %FastDecimal{coef: 1, exp: -65535}} = FastDecimal.parse("1e-65535")
    end

    test "accepts exponents in any normal range" do
      for n <- [0, 1, 10, 100, 1000, 6144, 10_000] do
        assert {:ok, _} = FastDecimal.parse("1e#{n}")
      end
    end

    test "FastDecimal.new/1 raises on the same inputs (uses parser internally)" do
      assert_raise ArgumentError, fn -> FastDecimal.new("1e1000000000") end
    end

    test "FastDecimal.cast/1 returns :error (doesn't raise) on the same inputs" do
      assert :error = FastDecimal.cast("1e1000000000")
    end
  end

  describe "pow10 cap: block arithmetic on huge-exp values constructed directly" do
    test "add(huge, _) raises rather than runs away" do
      # Direct construction bypasses the parser — but operations still safe.
      huge = FastDecimal.new(1, 1_000_000_000)

      assert_raise ArgumentError, ~r/pow10\(1000000000\).*denial-of-service/, fn ->
        FastDecimal.add(huge, FastDecimal.new(1))
      end
    end

    test "sub(huge, _) is also blocked" do
      huge = FastDecimal.new(1, 1_000_000_000)

      assert_raise ArgumentError, ~r/pow10/, fn ->
        FastDecimal.sub(huge, FastDecimal.new(1))
      end
    end

    test "compare(huge, _) is blocked (different-exp path uses pow10)" do
      huge = FastDecimal.new(1, 1_000_000_000)

      assert_raise ArgumentError, ~r/pow10/, fn ->
        FastDecimal.compare(huge, FastDecimal.new(1))
      end
    end

    test "operations between two huge-exp values stay safe (no alignment needed)" do
      # Same exp → no pow10 call.
      h1 = FastDecimal.new(1, 1_000_000_000)
      h2 = FastDecimal.new(1, 1_000_000_000)
      assert %FastDecimal{coef: 2, exp: 1_000_000_000} = FastDecimal.add(h1, h2)

      # mult adds exps, no alignment.
      assert %FastDecimal{coef: 1, exp: 2_000_000_000} = FastDecimal.mult(h1, h2)
    end

    test "the threshold itself behaves correctly" do
      # pow10(100_001) should raise.
      d = FastDecimal.new(1, 100_001)

      assert_raise ArgumentError, fn ->
        FastDecimal.add(d, FastDecimal.new(1))
      end

      # pow10(100_000) should be the largest allowed.
      d_safe = FastDecimal.new(1, 100_000)
      # Doesn't raise — but doesn't necessarily produce a sensible result
      # either; the point is just that we don't run-away allocate.
      result = FastDecimal.add(d_safe, FastDecimal.new(1))
      assert is_integer(result.coef)
    end
  end

  describe "to_string layer: refuse huge output" do
    test "to_string(_, :normal) on positive huge exp raises" do
      huge = FastDecimal.new(1, 1_000_000_000)

      assert_raise ArgumentError, ~r/would emit.*CVE-2026-32686/, fn ->
        FastDecimal.to_string(huge, :normal)
      end
    end

    test "to_string(_, :normal) on huge negative exp raises" do
      tiny = FastDecimal.new(1, -1_000_000_000)

      assert_raise ArgumentError, ~r/CVE-2026-32686/, fn ->
        FastDecimal.to_string(tiny, :normal)
      end
    end

    test ":scientific format works on extreme-exp values (no materialization)" do
      huge = FastDecimal.new(1, 1_000_000_000)
      assert FastDecimal.to_string(huge, :scientific) == "1E+1000000000"

      tiny = FastDecimal.new(1, -1_000_000_000)
      assert FastDecimal.to_string(tiny, :scientific) == "1E-1000000000"
    end

    test ":raw format works on extreme-exp values" do
      huge = FastDecimal.new(1, 1_000_000_000)
      assert FastDecimal.to_string(huge, :raw) == "1E+1000000000"
    end

    test "outputs up to ~1 MB still work" do
      # 100,000-byte output is well under the 1 MB cap.
      d = FastDecimal.new(1, 100_000)
      s = FastDecimal.to_string(d, :normal)
      assert byte_size(s) == 100_001
      assert String.starts_with?(s, "1")
    end
  end

  describe "zero-coefficient short-circuits (mirrors decimal v2.4.1 fix)" do
    # decimal v2.4.1 fixed an infinite loop in normalize/to_integer when
    # coef: 0 and exp != 0 (rem(0, 10) == 0 → div(0, 10) == 0 forever).
    # Our normalize/1 already short-circuits on coef: 0. These tests cover
    # the conversion-side fix: a zero value with a huge exponent should
    # return 0 (the obvious answer) rather than tripping the pow10 cap.
    test "to_integer/1 on zero-coef + huge negative exp returns 0" do
      assert FastDecimal.to_integer(%FastDecimal{coef: 0, exp: -1_000_000_000}) == 0
      assert FastDecimal.to_integer(%FastDecimal{coef: 0, exp: -5_000}) == 0
      assert FastDecimal.to_integer(FastDecimal.new("0.0")) == 0
      assert FastDecimal.to_integer(FastDecimal.new("0.000")) == 0
      assert FastDecimal.to_integer(FastDecimal.new("-0.0")) == 0
    end

    test "to_integer/1 on zero-coef + huge positive exp returns 0" do
      assert FastDecimal.to_integer(%FastDecimal{coef: 0, exp: 1_000_000_000}) == 0
    end

    test "to_float/1 on zero-coef + huge exp returns 0.0" do
      assert FastDecimal.to_float(%FastDecimal{coef: 0, exp: -1_000_000_000}) == 0.0
      assert FastDecimal.to_float(%FastDecimal{coef: 0, exp: 1_000_000_000}) == 0.0
    end

    test "normalize/1 on zero-coef + huge exp returns canonical zero" do
      assert FastDecimal.normalize(%FastDecimal{coef: 0, exp: -1_000_000_000}) ==
               %FastDecimal{coef: 0, exp: 0}

      assert FastDecimal.normalize(%FastDecimal{coef: 0, exp: 1_000_000_000}) ==
               %FastDecimal{coef: 0, exp: 0}
    end
  end

  describe "no regression: existing inputs still parse and operate normally" do
    test "typical fintech values" do
      for s <- ["1.23", "1234567890.123456789", "0.0001", "-42.5", "1e-6", "1e6"] do
        assert {:ok, _} = FastDecimal.parse(s)
        d = FastDecimal.new(s)
        # Round-trip
        assert FastDecimal.equal?(FastDecimal.new(FastDecimal.to_string(d)), d)
      end
    end

    test "arithmetic on typical values" do
      a = FastDecimal.new("1234.56789")
      b = FastDecimal.new("9876.54321")

      assert %FastDecimal{} = FastDecimal.add(a, b)
      assert %FastDecimal{} = FastDecimal.sub(a, b)
      assert %FastDecimal{} = FastDecimal.mult(a, b)
      assert %FastDecimal{} = FastDecimal.div(a, b)
      assert FastDecimal.compare(a, b) in [:lt, :eq, :gt]
    end

    test "scientific notation in normal range" do
      for s <- ["1e10", "1e-10", "1.5e100", "1e-1000", "1e6144"] do
        assert {:ok, d} = FastDecimal.parse(s)
        # And the value round-trips
        assert FastDecimal.equal?(FastDecimal.new(FastDecimal.to_string(d, :scientific)), d)
      end
    end
  end
end
