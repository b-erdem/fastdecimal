defmodule FastDecimal.CompatTest do
  use ExUnit.Case, async: true

  alias FastDecimal.Compat, as: Shim

  describe "drop-in arithmetic" do
    test "new/1 from string or integer" do
      assert Shim.new("1.23") == %FastDecimal{coef: 123, exp: -2}
      assert Shim.new(42) == %FastDecimal{coef: 42, exp: 0}
    end

    test "new/3 sign + coef + exp" do
      assert Shim.new(1, 123, -2) == %FastDecimal{coef: 123, exp: -2}
      assert Shim.new(-1, 123, -2) == %FastDecimal{coef: -123, exp: -2}
    end

    test "add accepts mixed input types" do
      assert Shim.add("1.5", 2) |> FastDecimal.equal?(%FastDecimal{coef: 35, exp: -1})
      assert Shim.add(Shim.new("1.5"), "2.5") |> FastDecimal.equal?(FastDecimal.new("4.0"))
    end

    test "sub, mult, div" do
      assert Shim.sub("10", "3") |> FastDecimal.equal?(FastDecimal.new("7"))
      assert Shim.mult("2.5", "4") |> FastDecimal.equal?(FastDecimal.new("10"))
      assert Shim.div("10", "4") |> FastDecimal.equal?(FastDecimal.new("2.5"))
    end

    test "div default precision is 28 (Decimal-compatible)" do
      result = Shim.div("1", "3")
      assert FastDecimal.to_string(result) |> String.length() >= 28
    end

    test "compare, equal?, eq?" do
      assert Shim.compare("1", "2") == :lt
      assert Shim.equal?("1.10", "1.1")
      assert Shim.eq?("1.10", "1.1")
    end

    test "to_string/1 and to_string/2" do
      assert Shim.to_string("1.23") == "1.23"
      assert Shim.to_string("1.23", :normal) == "1.23"
    end

    test "predicates" do
      assert Shim.zero?("0.0")
      refute Shim.zero?("0.1")
      assert Shim.positive?("1")
      refute Shim.positive?("-1")
      assert Shim.negative?("-1")
      assert Shim.integer?("42")
      refute Shim.integer?("1.5")
    end

    test "min, max, negate, abs" do
      assert Shim.min("1", "2") |> FastDecimal.equal?(FastDecimal.new("1"))
      assert Shim.max("1", "2") |> FastDecimal.equal?(FastDecimal.new("2"))
      assert Shim.negate("1.23") |> FastDecimal.equal?(FastDecimal.new("-1.23"))
      assert Shim.abs("-1.23") |> FastDecimal.equal?(FastDecimal.new("1.23"))
    end
  end

  describe "real Decimal struct interop" do
    test "coerces a real Decimal value into FastDecimal" do
      real = Decimal.new("-2.5")
      assert Shim.add(real, "1.5") |> FastDecimal.equal?(FastDecimal.new("-1.0"))
      assert Shim.mult(real, "2") |> FastDecimal.equal?(FastDecimal.new("-5.0"))
    end

    test "coerces with negative sign field" do
      real = %Decimal{sign: -1, coef: 100, exp: -1}
      assert Shim.add(real, real) |> FastDecimal.equal?(FastDecimal.new("-20.0"))
    end
  end

  describe "from_float/1" do
    test "round-trips a clean float" do
      assert Shim.from_float(0.5) |> FastDecimal.equal?(FastDecimal.new("0.5"))
    end

    test "matches Float.to_string round-trip (Decimal-compatible behavior)" do
      # Elixir's Float.to_string uses shortest round-trip representation,
      # so `from_float(1.1)` yields "1.1" — same as Decimal.from_float.
      assert Shim.from_float(1.1) |> FastDecimal.equal?(FastDecimal.new("1.1"))
    end
  end
end
