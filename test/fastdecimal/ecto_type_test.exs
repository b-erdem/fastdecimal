if Code.ensure_loaded?(Ecto.Type) do
  defmodule FastDecimal.Ecto.TypeTest do
    use ExUnit.Case, async: true

    alias FastDecimal.Ecto.Type

    test "type/0 reports :decimal" do
      assert Type.type() == :decimal
    end

    describe "cast/1" do
      test "accepts FastDecimal struct unchanged" do
        d = FastDecimal.new("1.23")
        assert Type.cast(d) == {:ok, d}
      end

      test "accepts string" do
        assert {:ok, %FastDecimal{coef: 123, exp: -2}} = Type.cast("1.23")
      end

      test "accepts integer" do
        assert {:ok, %FastDecimal{coef: 42, exp: 0}} = Type.cast(42)
      end

      test "accepts Decimal struct" do
        assert {:ok, %FastDecimal{coef: 123, exp: -2}} = Type.cast(Decimal.new("1.23"))
      end

      test "rejects garbage" do
        assert Type.cast("abc") == :error
        assert Type.cast(nil) == :error
      end
    end

    describe "load/1 (from DB)" do
      test "loads Decimal struct (the postgrex shape)" do
        assert {:ok, %FastDecimal{coef: 1234, exp: -2}} = Type.load(Decimal.new("12.34"))
      end

      test "loads negative Decimal" do
        assert {:ok, %FastDecimal{coef: -50, exp: -1}} = Type.load(Decimal.new("-5.0"))
      end

      test "loads integer" do
        assert {:ok, %FastDecimal{coef: 100, exp: 0}} = Type.load(100)
      end

      test "loads string (some adapters)" do
        assert {:ok, %FastDecimal{coef: 999, exp: -2}} = Type.load("9.99")
      end
    end

    describe "dump/1 (to DB)" do
      test "dumps to Decimal struct" do
        fd = FastDecimal.new("12.34")
        assert {:ok, %Decimal{sign: 1, coef: 1234, exp: -2}} = Type.dump(fd)
      end

      test "dumps negative correctly" do
        fd = FastDecimal.new("-5.0")
        assert {:ok, %Decimal{sign: -1, coef: 50, exp: -1}} = Type.dump(fd)
      end

      test "dumps NaN / Infinity" do
        assert {:ok, %Decimal{coef: :NaN}} = Type.dump(FastDecimal.nan())
        assert {:ok, %Decimal{coef: :inf, sign: 1}} = Type.dump(FastDecimal.inf())
        assert {:ok, %Decimal{coef: :inf, sign: -1}} = Type.dump(FastDecimal.neg_inf())
      end
    end

    test "equal?/2 compares semantic values across input types" do
      assert Type.equal?(FastDecimal.new("1.10"), FastDecimal.new("1.1"))
      assert Type.equal?(FastDecimal.new("1.10"), Decimal.new("1.1"))
      assert Type.equal?("1.10", "1.1")
      refute Type.equal?("1.10", "1.2")
    end

    test "round-trip: cast → dump → load preserves value" do
      original = FastDecimal.new("123.456")
      {:ok, dumped} = Type.dump(original)
      {:ok, loaded} = Type.load(dumped)
      assert FastDecimal.equal?(original, loaded)
    end
  end
end
