defmodule FastDecimal.Compat do
  @moduledoc """
  `Decimal`-API-shaped facade. Drop in to migrate existing code:

      alias FastDecimal.Compat, as: Decimal

  Every `Decimal.foo(...)` call in the existing code then routes here, which
  delegates to `FastDecimal`. Inputs are auto-coerced (`Decimal` struct,
  `FastDecimal` struct, integer, binary, float).

  ## Limitations

    * **Struct literals don't translate under alias.** `%Decimal{sign: 1,
      coef: 123, exp: -2}` resolves to the aliased module — there is no such
      struct here. Replace with `Decimal.new(1, 123, -2)` (3-arg form, shimmed).
    * `Decimal.Context.*` is intentionally not shimmed — FastDecimal does not
      carry an implicit precision context. See the `FastDecimal` moduledoc.
      Pass precision per-call via `div/3`'s opts.
    * For `Decimal.Macros.is_decimal/1`, use `FastDecimal.is_decimal/1`
      (same shape, importable as `import FastDecimal, only: [is_decimal: 1]`).
  """

  alias FastDecimal

  @type input ::
          FastDecimal.t() | Decimal.t() | integer() | binary() | float() | nil

  # ---- Coercion -----------------------------------------------------------

  @doc false
  @spec coerce(input()) :: FastDecimal.t()
  def coerce(%FastDecimal{} = d), do: d

  def coerce(%Decimal{sign: sign, coef: coef, exp: exp}) when is_integer(coef),
    do: %FastDecimal{coef: sign * coef, exp: exp}

  def coerce(%Decimal{sign: 1, coef: :NaN}), do: FastDecimal.nan()
  def coerce(%Decimal{sign: 1, coef: :inf}), do: FastDecimal.inf()
  def coerce(%Decimal{sign: -1, coef: :inf}), do: FastDecimal.neg_inf()

  def coerce(int) when is_integer(int), do: FastDecimal.new(int)
  def coerce(str) when is_binary(str), do: FastDecimal.new(str)
  def coerce(float) when is_float(float), do: from_float(float)

  # ---- Construction -------------------------------------------------------

  @spec new(input()) :: FastDecimal.t()
  def new(input), do: FastDecimal.new(input)

  @doc "Decimal-style 3-arg constructor: sign (`1` or `-1`), coef, exp."
  @spec new(1 | -1, non_neg_integer(), integer()) :: FastDecimal.t()
  def new(1, coef, exp) when is_integer(coef) and is_integer(exp),
    do: %FastDecimal{coef: coef, exp: exp}

  def new(-1, coef, exp) when is_integer(coef) and is_integer(exp),
    do: %FastDecimal{coef: -coef, exp: exp}

  @spec from_float(float()) :: FastDecimal.t()
  def from_float(float) when is_float(float) do
    {:ok, d} = FastDecimal.cast(float)
    d
  end

  @doc "Soft constructor — returns `{:ok, t} | :error`. Mirrors `c:Ecto.Type.cast/1`-like input handling."
  @spec cast(input()) :: {:ok, FastDecimal.t()} | :error
  defdelegate cast(value), to: FastDecimal

  # ---- Constants ----------------------------------------------------------

  @spec nan() :: FastDecimal.t()
  defdelegate nan(), to: FastDecimal
  @spec inf() :: FastDecimal.t()
  defdelegate inf(), to: FastDecimal
  @spec neg_inf() :: FastDecimal.t()
  defdelegate neg_inf(), to: FastDecimal

  # ---- Arithmetic ---------------------------------------------------------

  @spec add(input(), input()) :: FastDecimal.t()
  def add(a, b), do: FastDecimal.add(coerce(a), coerce(b))

  @spec sub(input(), input()) :: FastDecimal.t()
  def sub(a, b), do: FastDecimal.sub(coerce(a), coerce(b))

  @spec mult(input(), input()) :: FastDecimal.t()
  def mult(a, b), do: FastDecimal.mult(coerce(a), coerce(b))

  @spec multiply(input(), input()) :: FastDecimal.t()
  defdelegate multiply(a, b), to: __MODULE__, as: :mult

  @spec minus(input()) :: FastDecimal.t()
  def minus(a), do: FastDecimal.negate(coerce(a))

  @spec negate(input()) :: FastDecimal.t()
  defdelegate negate(a), to: __MODULE__, as: :minus

  @spec abs(input()) :: FastDecimal.t()
  def abs(a), do: FastDecimal.abs(coerce(a))

  @spec plus(input()) :: FastDecimal.t()
  def plus(a), do: coerce(a)

  @doc """
  Division. Defaults to precision 28 (matching Decimal's default context).
  Pass `precision:` and/or `rounding:` opts to override.
  """
  @spec div(input(), input(), keyword()) :: FastDecimal.t()
  def div(a, b, opts \\ []) do
    opts = Keyword.put_new(opts, :precision, 28)
    FastDecimal.div(coerce(a), coerce(b), opts)
  end

  @spec div_int(input(), input()) :: FastDecimal.t()
  def div_int(a, b), do: FastDecimal.div_int(coerce(a), coerce(b))

  @spec div_rem(input(), input()) :: {FastDecimal.t(), FastDecimal.t()}
  def div_rem(a, b), do: FastDecimal.div_rem(coerce(a), coerce(b))

  @spec rem(input(), input()) :: FastDecimal.t()
  def rem(a, b), do: FastDecimal.rem(coerce(a), coerce(b))

  @spec sqrt(input(), keyword()) :: FastDecimal.t()
  def sqrt(a, opts \\ []), do: FastDecimal.sqrt(coerce(a), opts)

  @spec round(input(), integer(), FastDecimal.rounding_mode()) :: FastDecimal.t()
  def round(a, places \\ 0, mode \\ :half_up) do
    # Decimal's default rounding is :half_up; FastDecimal uses :half_even. We
    # honor Decimal's convention here so drop-in semantics match.
    FastDecimal.round(coerce(a), places, mode)
  end

  # ---- Comparison ---------------------------------------------------------

  @spec compare(input(), input()) :: :lt | :eq | :gt | :nan
  def compare(a, b), do: FastDecimal.compare(coerce(a), coerce(b))

  @spec cmp(input(), input()) :: :lt | :eq | :gt | :nan
  def cmp(a, b), do: FastDecimal.compare(coerce(a), coerce(b))

  @spec equal?(input(), input()) :: boolean()
  def equal?(a, b), do: FastDecimal.equal?(coerce(a), coerce(b))

  @spec eq?(input(), input()) :: boolean()
  defdelegate eq?(a, b), to: __MODULE__, as: :equal?

  @spec lt?(input(), input()) :: boolean()
  def lt?(a, b), do: FastDecimal.lt?(coerce(a), coerce(b))

  @spec gt?(input(), input()) :: boolean()
  def gt?(a, b), do: FastDecimal.gt?(coerce(a), coerce(b))

  @spec min(input(), input()) :: FastDecimal.t()
  def min(a, b), do: FastDecimal.min(coerce(a), coerce(b))

  @spec max(input(), input()) :: FastDecimal.t()
  def max(a, b), do: FastDecimal.max(coerce(a), coerce(b))

  # ---- Predicates ---------------------------------------------------------

  @spec zero?(input()) :: boolean()
  def zero?(a), do: FastDecimal.zero?(coerce(a))

  @spec positive?(input()) :: boolean()
  def positive?(a), do: FastDecimal.positive?(coerce(a))

  @spec negative?(input()) :: boolean()
  def negative?(a), do: FastDecimal.negative?(coerce(a))

  @spec nan?(input()) :: boolean()
  def nan?(a), do: FastDecimal.nan?(coerce(a))

  @spec inf?(input()) :: boolean()
  def inf?(a), do: FastDecimal.inf?(coerce(a))

  @spec finite?(input()) :: boolean()
  def finite?(a), do: FastDecimal.finite?(coerce(a))

  @spec integer?(input()) :: boolean()
  def integer?(d) do
    case FastDecimal.normalize(coerce(d)) do
      %FastDecimal{exp: e} when e >= 0 -> true
      _ -> false
    end
  end

  # ---- Conversion ---------------------------------------------------------

  @spec to_string(input()) :: String.t()
  def to_string(a), do: FastDecimal.to_string(coerce(a))

  @spec to_string(input(), FastDecimal.to_string_format()) :: String.t()
  def to_string(a, format), do: FastDecimal.to_string(coerce(a), format)

  @spec to_integer(input()) :: integer()
  def to_integer(a), do: FastDecimal.to_integer(coerce(a))

  @spec to_float(input()) :: float()
  def to_float(a), do: FastDecimal.to_float(coerce(a))

  @spec normalize(input()) :: FastDecimal.t()
  def normalize(a), do: FastDecimal.normalize(coerce(a))

  @spec reduce(input()) :: FastDecimal.t()
  defdelegate reduce(a), to: __MODULE__, as: :normalize
end
