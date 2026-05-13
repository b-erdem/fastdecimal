defmodule FastDecimal.ParserTest do
  @moduledoc """
  Comprehensive parser coverage. Catches regressions in scientific notation
  handling, special-value strings, sign handling, and malformed-input rejection.
  """

  use ExUnit.Case, async: true

  alias FastDecimal.Parser

  describe "normal numeric strings" do
    test "single digit" do
      assert {:ok, {0, 0}} = Parser.parse("0")
      assert {:ok, {5, 0}} = Parser.parse("5")
      assert {:ok, {9, 0}} = Parser.parse("9")
    end

    test "multi-digit integers" do
      assert {:ok, {42, 0}} = Parser.parse("42")
      assert {:ok, {1_234_567_890, 0}} = Parser.parse("1234567890")
    end

    test "fractional numbers" do
      assert {:ok, {123, -2}} = Parser.parse("1.23")
      assert {:ok, {1, -1}} = Parser.parse("0.1")
      assert {:ok, {1, -10}} = Parser.parse("0.0000000001")
    end

    test "leading dot" do
      assert {:ok, {5, -1}} = Parser.parse(".5")
      assert {:ok, {123, -3}} = Parser.parse(".123")
    end

    test "trailing dot" do
      assert {:ok, {5, 0}} = Parser.parse("5.")
      assert {:ok, {123, 0}} = Parser.parse("123.")
    end

    test "leading zeros preserved in fractional" do
      assert {:ok, {1, -5}} = Parser.parse("0.00001")
    end

    test "trailing zeros preserved" do
      assert {:ok, {1_000, 0}} = Parser.parse("1000")
      assert {:ok, {110, -2}} = Parser.parse("1.10")
    end
  end

  describe "signs" do
    test "explicit positive" do
      assert {:ok, {42, 0}} = Parser.parse("+42")
      assert {:ok, {123, -2}} = Parser.parse("+1.23")
    end

    test "negative" do
      assert {:ok, {-42, 0}} = Parser.parse("-42")
      assert {:ok, {-123, -2}} = Parser.parse("-1.23")
      assert {:ok, {-1, -3}} = Parser.parse("-0.001")
    end

    test "negative zero parses as zero" do
      assert {:ok, {0, 0}} = Parser.parse("-0")
      assert {:ok, {0, -2}} = Parser.parse("-0.00")
    end
  end

  describe "scientific notation" do
    test "lowercase e" do
      assert {:ok, {1, 10}} = Parser.parse("1e10")
      assert {:ok, {123, 8}} = Parser.parse("1.23e10")
    end

    test "uppercase E" do
      assert {:ok, {1, 10}} = Parser.parse("1E10")
      assert {:ok, {123, 8}} = Parser.parse("1.23E10")
    end

    test "explicit positive exponent" do
      assert {:ok, {1, 5}} = Parser.parse("1e+5")
      assert {:ok, {123, 3}} = Parser.parse("1.23e+5")
    end

    test "negative exponent" do
      assert {:ok, {1, -5}} = Parser.parse("1e-5")
      assert {:ok, {123, -7}} = Parser.parse("1.23e-5")
    end

    test "zero exponent" do
      assert {:ok, {123, -2}} = Parser.parse("1.23e0")
      assert {:ok, {123, -2}} = Parser.parse("1.23E+0")
    end

    test "large exponents" do
      assert {:ok, {1, 100}} = Parser.parse("1e100")
      assert {:ok, {1, -100}} = Parser.parse("1e-100")
    end

    test "integer mantissa with exponent" do
      assert {:ok, {5, 3}} = Parser.parse("5e3")
      assert {:ok, {5, -3}} = Parser.parse("5e-3")
    end

    test "fractional mantissa with exponent" do
      assert {:ok, {5, -1}} = Parser.parse(".5e0")
      assert {:ok, {5, 2}} = Parser.parse(".5e3")
    end

    test "negative mantissa with exponent" do
      assert {:ok, {-15, -1}} = Parser.parse("-1.5e0")
      assert {:ok, {-15, 5}} = Parser.parse("-1.5e+6")
    end
  end

  describe "special-value strings" do
    test "NaN" do
      assert {:ok, {:nan, 0}} = Parser.parse("NaN")
      assert {:ok, {:nan, 0}} = Parser.parse("nan")
    end

    test "Infinity (full word)" do
      assert {:ok, {:inf, 0}} = Parser.parse("Infinity")
      assert {:ok, {:neg_inf, 0}} = Parser.parse("-Infinity")
      assert {:ok, {:inf, 0}} = Parser.parse("+Infinity")
    end

    test "Inf (short form)" do
      assert {:ok, {:inf, 0}} = Parser.parse("Inf")
      assert {:ok, {:inf, 0}} = Parser.parse("inf")
      assert {:ok, {:neg_inf, 0}} = Parser.parse("-Inf")
      assert {:ok, {:neg_inf, 0}} = Parser.parse("-inf")
      assert {:ok, {:inf, 0}} = Parser.parse("+Inf")
    end
  end

  describe "malformed inputs" do
    test "empty string" do
      assert :error = Parser.parse("")
    end

    test "non-numeric" do
      assert :error = Parser.parse("abc")
      assert :error = Parser.parse("hello")
      assert :error = Parser.parse("foo123")
    end

    test "trailing garbage" do
      assert :error = Parser.parse("1.23abc")
      assert :error = Parser.parse("42foo")
    end

    test "leading garbage" do
      assert :error = Parser.parse("abc1.23")
      assert :error = Parser.parse("$42")
    end

    test "multiple decimal points" do
      assert :error = Parser.parse("1.2.3")
      assert :error = Parser.parse("1..2")
    end

    test "lone signs / dots" do
      assert :error = Parser.parse("+")
      assert :error = Parser.parse("-")
      assert :error = Parser.parse(".")
      assert :error = Parser.parse("++1")
      assert :error = Parser.parse("--1")
    end

    test "malformed scientific notation" do
      assert :error = Parser.parse("1e")
      assert :error = Parser.parse("1e-")
      assert :error = Parser.parse("1e+")
      assert :error = Parser.parse("1ee5")
      assert :error = Parser.parse("e10")
      assert :error = Parser.parse(".e5")
      assert :error = Parser.parse("1.e")
    end

    test "whitespace not allowed" do
      assert :error = Parser.parse(" 1.23")
      assert :error = Parser.parse("1.23 ")
      assert :error = Parser.parse("1 .23")
      assert :error = Parser.parse("1.2 3")
    end
  end

  describe "very long inputs" do
    test "100-digit integer" do
      str = String.duplicate("9", 100)
      assert {:ok, {n, 0}} = Parser.parse(str)
      assert n == String.to_integer(str)
    end

    test "100-digit fraction" do
      str = "0." <> String.duplicate("9", 100)
      assert {:ok, {n, -100}} = Parser.parse(str)
      assert n == String.to_integer(String.duplicate("9", 100))
    end
  end

  describe "split-strategy parser matches walk-strategy on numeric inputs" do
    # Cross-checks the two implementations (we keep `parse_split` around for
    # bench/parse.exs comparison). Both should produce identical results on
    # numeric inputs.
    test "agrees on all the normal cases" do
      cases = [
        "0",
        "1",
        "1.23",
        "-1.23",
        "+42",
        ".5",
        "5.",
        "0.001",
        "123456789",
        "1234567890.123456789",
        "-0.0000000001"
      ]

      for s <- cases do
        assert Parser.parse_walk(s) == Parser.parse_split(s),
               "split/walk disagreed on #{inspect(s)}"
      end
    end
  end

  describe "round-trip integrity" do
    test "every roundtrip preserves the value through to_string :normal" do
      cases = [
        "0",
        "1.23",
        "-1.23",
        "0.001",
        "1000",
        "123456789.987654321",
        "-0.0000000001"
      ]

      for s <- cases do
        d = FastDecimal.new(s)
        str = FastDecimal.to_string(d)
        assert FastDecimal.equal?(FastDecimal.new(str), d), "round-trip failed: #{s}"
      end
    end

    test "every roundtrip preserves through :scientific" do
      cases = ["0", "1.23", "0.001", "1234.56789", "-42.5"]

      for s <- cases do
        d = FastDecimal.new(s)
        sci = FastDecimal.to_string(d, :scientific)

        assert FastDecimal.equal?(FastDecimal.new(sci), d),
               "scientific round-trip failed: #{s} -> #{sci}"
      end
    end
  end
end
