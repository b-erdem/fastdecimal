defmodule FastDecimal.PropertyTest do
  @moduledoc """
  Property-based tests via `StreamData`. These capture mathematical invariants
  that must hold for *any* FastDecimal input. They're the regression gate:
  future performance optimizations have to keep these properties true.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  # ---- Generators ---------------------------------------------------------

  defp decimal_gen do
    gen all(
          coef <- integer(-1_000_000..1_000_000),
          exp <- integer(-12..12)
        ) do
      %FastDecimal{coef: coef, exp: exp}
    end
  end

  defp nonzero_decimal_gen do
    StreamData.filter(decimal_gen(), &(&1.coef != 0))
  end

  defp finite_pair_gen do
    StreamData.tuple({decimal_gen(), decimal_gen()})
  end

  # ---- Construction & round-trip -----------------------------------------

  property "parse(to_string(x)) preserves value" do
    check all(d <- decimal_gen()) do
      str = FastDecimal.to_string(d)
      assert {:ok, parsed} = FastDecimal.parse(str)
      assert FastDecimal.equal?(parsed, d)
    end
  end

  property "to_string(:scientific) round-trips" do
    check all(d <- decimal_gen()) do
      str = FastDecimal.to_string(d, :scientific)
      assert {:ok, parsed} = FastDecimal.parse(str)
      assert FastDecimal.equal?(parsed, d)
    end
  end

  property "to_string(:raw) round-trips" do
    check all(d <- decimal_gen()) do
      str = FastDecimal.to_string(d, :raw)
      assert {:ok, parsed} = FastDecimal.parse(str)
      assert FastDecimal.equal?(parsed, d)
    end
  end

  property "new(int, exp) matches struct construction" do
    check all(coef <- integer(), exp <- integer(-100..100)) do
      assert FastDecimal.new(coef, exp) == %FastDecimal{coef: coef, exp: exp}
    end
  end

  # ---- Arithmetic invariants ---------------------------------------------

  property "add is commutative" do
    check all({a, b} <- finite_pair_gen()) do
      assert FastDecimal.equal?(FastDecimal.add(a, b), FastDecimal.add(b, a))
    end
  end

  property "add is associative" do
    check all(a <- decimal_gen(), b <- decimal_gen(), c <- decimal_gen()) do
      lhs = FastDecimal.add(FastDecimal.add(a, b), c)
      rhs = FastDecimal.add(a, FastDecimal.add(b, c))
      assert FastDecimal.equal?(lhs, rhs)
    end
  end

  property "0 is additive identity" do
    check all(a <- decimal_gen()) do
      zero = FastDecimal.new(0)
      assert FastDecimal.equal?(FastDecimal.add(a, zero), a)
      assert FastDecimal.equal?(FastDecimal.add(zero, a), a)
    end
  end

  property "a - a == 0 for any finite a" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.equal?(FastDecimal.sub(a, a), FastDecimal.new(0))
    end
  end

  property "a + (-a) == 0" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.equal?(FastDecimal.add(a, FastDecimal.negate(a)), FastDecimal.new(0))
    end
  end

  property "negate is involutive" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.equal?(FastDecimal.negate(FastDecimal.negate(a)), a)
    end
  end

  property "abs(x) >= 0" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.compare(FastDecimal.abs(a), FastDecimal.new(0)) in [:eq, :gt]
    end
  end

  property "abs is idempotent" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.equal?(FastDecimal.abs(FastDecimal.abs(a)), FastDecimal.abs(a))
    end
  end

  property "mult is commutative" do
    check all({a, b} <- finite_pair_gen()) do
      assert FastDecimal.equal?(FastDecimal.mult(a, b), FastDecimal.mult(b, a))
    end
  end

  property "1 is multiplicative identity" do
    check all(a <- decimal_gen()) do
      one = FastDecimal.new(1)
      assert FastDecimal.equal?(FastDecimal.mult(a, one), a)
      assert FastDecimal.equal?(FastDecimal.mult(one, a), a)
    end
  end

  property "0 absorbs multiplication" do
    check all(a <- decimal_gen()) do
      zero = FastDecimal.new(0)
      assert FastDecimal.equal?(FastDecimal.mult(a, zero), zero)
    end
  end

  property "mult distributes over add" do
    check all(a <- decimal_gen(), b <- decimal_gen(), c <- decimal_gen()) do
      # a * (b + c) == a*b + a*c
      lhs = FastDecimal.mult(a, FastDecimal.add(b, c))
      rhs = FastDecimal.add(FastDecimal.mult(a, b), FastDecimal.mult(a, c))
      assert FastDecimal.equal?(lhs, rhs)
    end
  end

  property "(-a) * b == -(a*b)" do
    check all(a <- decimal_gen(), b <- decimal_gen()) do
      lhs = FastDecimal.mult(FastDecimal.negate(a), b)
      rhs = FastDecimal.negate(FastDecimal.mult(a, b))
      assert FastDecimal.equal?(lhs, rhs)
    end
  end

  # ---- Division invariants -----------------------------------------------

  property "div_rem invariant: a == q*b + r" do
    check all(a <- decimal_gen(), b <- nonzero_decimal_gen()) do
      {q, r} = FastDecimal.div_rem(a, b)
      reconstructed = FastDecimal.add(FastDecimal.mult(q, b), r)

      assert FastDecimal.equal?(reconstructed, a),
             "div_rem broke: a=#{a}, b=#{b}, q=#{q}, r=#{r}, reconstructed=#{reconstructed}"
    end
  end

  property "div_int's result is integer-valued" do
    check all(a <- decimal_gen(), b <- nonzero_decimal_gen()) do
      result = FastDecimal.div_int(a, b)
      assert result.exp == 0
    end
  end

  property "div produces approximately a/b (within rounding)" do
    check all(a <- decimal_gen(), b <- nonzero_decimal_gen()) do
      result = FastDecimal.div(a, b, precision: 28)
      reconstructed = FastDecimal.mult(result, b)
      # reconstructed should be close to a
      diff = FastDecimal.abs(FastDecimal.sub(reconstructed, a))
      tolerance = FastDecimal.mult(FastDecimal.abs(a), FastDecimal.new("1e-20"))
      tolerance = FastDecimal.max(tolerance, FastDecimal.new("1e-20"))

      assert FastDecimal.compare(diff, tolerance) in [:lt, :eq],
             "div imprecise: #{a} / #{b} = #{result}, reconstructed=#{reconstructed}"
    end
  end

  # ---- Comparison invariants ---------------------------------------------

  property "compare is antisymmetric for finite values" do
    check all({a, b} <- finite_pair_gen()) do
      ab = FastDecimal.compare(a, b)
      ba = FastDecimal.compare(b, a)

      case {ab, ba} do
        {:lt, :gt} -> :ok
        {:gt, :lt} -> :ok
        {:eq, :eq} -> :ok
        other -> flunk("compare not antisymmetric: a=#{a}, b=#{b}, got #{inspect(other)}")
      end
    end
  end

  property "compare is reflexive" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.compare(a, a) == :eq
    end
  end

  property "equal? is symmetric" do
    check all(a <- decimal_gen(), b <- decimal_gen()) do
      assert FastDecimal.equal?(a, b) == FastDecimal.equal?(b, a)
    end
  end

  property "if a < b and b < c, then a < c (transitivity)" do
    check all(a <- decimal_gen(), b <- decimal_gen(), c <- decimal_gen()) do
      if FastDecimal.lt?(a, b) and FastDecimal.lt?(b, c) do
        assert FastDecimal.lt?(a, c),
               "transitivity broken: a=#{a} < b=#{b} < c=#{c} but a < c is false"
      end
    end
  end

  # ---- normalize / round invariants --------------------------------------

  property "normalize is idempotent" do
    check all(a <- decimal_gen()) do
      n = FastDecimal.normalize(a)
      assert FastDecimal.normalize(n) == n
    end
  end

  property "normalize preserves value" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.equal?(FastDecimal.normalize(a), a)
    end
  end

  property "round to N places gives result with exp >= -N" do
    check all(a <- decimal_gen(), places <- integer(-5..10)) do
      result = FastDecimal.round(a, places)

      if is_integer(result.coef) do
        assert result.exp >= -places,
               "round to #{places} places gave exp=#{result.exp} for input #{a}"
      end
    end
  end

  property "round with :down doesn't increase magnitude" do
    check all(a <- decimal_gen(), places <- integer(0..5)) do
      result = FastDecimal.round(a, places, :down)
      # |result| <= |a|
      assert FastDecimal.compare(FastDecimal.abs(result), FastDecimal.abs(a)) in [:lt, :eq]
    end
  end

  # ---- sqrt invariants ---------------------------------------------------

  property "sqrt(x)^2 ≈ x for positive x" do
    check all(coef <- integer(1..1_000_000), exp <- integer(-10..10)) do
      a = %FastDecimal{coef: coef, exp: exp}
      r = FastDecimal.sqrt(a, precision: 28)
      squared = FastDecimal.mult(r, r)
      diff = FastDecimal.abs(FastDecimal.sub(squared, a))
      # Tolerance relative to a's magnitude
      tolerance = FastDecimal.mult(FastDecimal.abs(a), FastDecimal.new("1e-20"))
      tolerance = FastDecimal.max(tolerance, FastDecimal.new("1e-20"))

      assert FastDecimal.compare(diff, tolerance) in [:lt, :eq],
             "sqrt(#{a})^2 = #{squared}, diff = #{diff}, tolerance = #{tolerance}"
    end
  end

  property "sqrt of negative returns NaN" do
    check all(coef <- integer(-1_000_000..-1), exp <- integer(-10..10)) do
      a = %FastDecimal{coef: coef, exp: exp}
      assert FastDecimal.nan?(FastDecimal.sqrt(a))
    end
  end

  # ---- Special-value propagation -----------------------------------------

  property "any op with NaN returns NaN (or :nan for compare)" do
    check all(a <- decimal_gen()) do
      nan = FastDecimal.nan()
      assert FastDecimal.nan?(FastDecimal.add(nan, a))
      assert FastDecimal.nan?(FastDecimal.add(a, nan))
      assert FastDecimal.nan?(FastDecimal.sub(nan, a))
      assert FastDecimal.nan?(FastDecimal.mult(nan, a))
      assert FastDecimal.nan?(FastDecimal.mult(a, nan))
      assert FastDecimal.compare(nan, a) == :nan
      assert FastDecimal.compare(a, nan) == :nan
      refute FastDecimal.equal?(nan, a)
    end
  end

  property "finite values are always finite?" do
    check all(a <- decimal_gen()) do
      assert FastDecimal.finite?(a)
      refute FastDecimal.nan?(a)
      refute FastDecimal.inf?(a)
    end
  end

  # ---- Compat shim invariants --------------------------------------------

  property "Compat.add accepts string, integer, Decimal interchangeably" do
    check all(
            coef1 <- integer(-100_000..100_000),
            exp1 <- integer(-6..6),
            coef2 <- integer(-100_000..100_000),
            exp2 <- integer(-6..6)
          ) do
      a_fd = %FastDecimal{coef: coef1, exp: exp1}
      b_fd = %FastDecimal{coef: coef2, exp: exp2}
      a_str = FastDecimal.to_string(a_fd)
      b_str = FastDecimal.to_string(b_fd)

      via_fd = FastDecimal.add(a_fd, b_fd)
      via_compat_str = FastDecimal.Compat.add(a_str, b_str)
      via_compat_mix = FastDecimal.Compat.add(a_fd, b_str)

      assert FastDecimal.equal?(via_fd, via_compat_str)
      assert FastDecimal.equal?(via_fd, via_compat_mix)
    end
  end

  # ---- Cross-check vs `decimal` (the lib we replace) ---------------------

  # ---- Cross-check vs Decimal (the lib we replace) ----------------------
  # Decimal uses a 28-digit precision context by default; FastDecimal does
  # exact arithmetic. Constrain inputs so the result stays within 28 sig figs
  # — otherwise Decimal rounds but we don't, and the values legitimately
  # diverge. (Tested by adding ±1e-50 to a 1e18 value: Decimal drops the
  # small term, FastDecimal keeps it. Documented design difference.)

  defp small_decimal_gen do
    gen all(
          coef <- integer(-100_000..100_000),
          exp <- integer(-6..6)
        ) do
      %FastDecimal{coef: coef, exp: exp}
    end
  end

  property "add matches Decimal.add when both fit in 28-digit precision" do
    check all(a <- small_decimal_gen(), b <- small_decimal_gen()) do
      a_str = FastDecimal.to_string(a)
      b_str = FastDecimal.to_string(b)

      fd_result = FastDecimal.add(a, b)
      dec_result = Decimal.add(Decimal.new(a_str), Decimal.new(b_str))
      fd_as_dec = FastDecimal.new(Decimal.to_string(dec_result, :normal))

      assert FastDecimal.equal?(fd_result, fd_as_dec),
             "add diverged: #{a} + #{b}: FastDecimal=#{fd_result}, Decimal=#{Decimal.to_string(dec_result, :normal)}"
    end
  end

  property "mult matches Decimal.mult when both fit in 28-digit precision" do
    check all(a <- small_decimal_gen(), b <- small_decimal_gen()) do
      fd_result = FastDecimal.mult(a, b)

      dec_result =
        Decimal.mult(Decimal.new(FastDecimal.to_string(a)), Decimal.new(FastDecimal.to_string(b)))

      fd_as_dec = FastDecimal.new(Decimal.to_string(dec_result, :normal))

      assert FastDecimal.equal?(fd_result, fd_as_dec),
             "mult diverged: #{a} * #{b}: FastDecimal=#{fd_result}, Decimal=#{Decimal.to_string(dec_result, :normal)}"
    end
  end
end
