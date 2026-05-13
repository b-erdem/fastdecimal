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

  def new(input), do: FastDecimal.new(input)

  @doc "Decimal-style 3-arg constructor: sign (`1` or `-1`), coef, exp."
  def new(1, coef, exp) when is_integer(coef) and is_integer(exp),
    do: %FastDecimal{coef: coef, exp: exp}

  def new(-1, coef, exp) when is_integer(coef) and is_integer(exp),
    do: %FastDecimal{coef: -coef, exp: exp}

  def from_float(float) when is_float(float) do
    {:ok, d} = FastDecimal.cast(float)
    d
  end

  @doc "Soft constructor — returns `{:ok, t} | :error`. Mirrors `Ecto.Type.cast/1`-like input handling."
  defdelegate cast(value), to: FastDecimal

  # ---- Constants ----------------------------------------------------------

  defdelegate nan(), to: FastDecimal
  defdelegate inf(), to: FastDecimal
  defdelegate neg_inf(), to: FastDecimal

  # ---- Arithmetic ---------------------------------------------------------

  def add(a, b), do: FastDecimal.add(coerce(a), coerce(b))
  def sub(a, b), do: FastDecimal.sub(coerce(a), coerce(b))
  def mult(a, b), do: FastDecimal.mult(coerce(a), coerce(b))
  defdelegate multiply(a, b), to: __MODULE__, as: :mult
  def minus(a), do: FastDecimal.negate(coerce(a))
  defdelegate negate(a), to: __MODULE__, as: :minus
  def abs(a), do: FastDecimal.abs(coerce(a))
  def plus(a), do: coerce(a)

  @doc """
  Division. Defaults to precision 28 (matching Decimal's default context).
  Pass `precision:` and/or `rounding:` opts to override.
  """
  def div(a, b, opts \\ []) do
    opts = Keyword.put_new(opts, :precision, 28)
    FastDecimal.div(coerce(a), coerce(b), opts)
  end

  def div_int(a, b), do: FastDecimal.div_int(coerce(a), coerce(b))
  def div_rem(a, b), do: FastDecimal.div_rem(coerce(a), coerce(b))
  def rem(a, b), do: FastDecimal.rem(coerce(a), coerce(b))

  def sqrt(a, opts \\ []), do: FastDecimal.sqrt(coerce(a), opts)

  def round(a, places \\ 0, mode \\ :half_up) do
    # Decimal's default rounding is :half_up; FastDecimal uses :half_even. We
    # honor Decimal's convention here so drop-in semantics match.
    FastDecimal.round(coerce(a), places, mode)
  end

  # ---- Comparison ---------------------------------------------------------

  def compare(a, b), do: FastDecimal.compare(coerce(a), coerce(b))
  def cmp(a, b), do: FastDecimal.compare(coerce(a), coerce(b))
  def equal?(a, b), do: FastDecimal.equal?(coerce(a), coerce(b))
  defdelegate eq?(a, b), to: __MODULE__, as: :equal?
  def lt?(a, b), do: FastDecimal.lt?(coerce(a), coerce(b))
  def gt?(a, b), do: FastDecimal.gt?(coerce(a), coerce(b))
  def min(a, b), do: FastDecimal.min(coerce(a), coerce(b))
  def max(a, b), do: FastDecimal.max(coerce(a), coerce(b))

  # ---- Predicates ---------------------------------------------------------

  def zero?(a), do: FastDecimal.zero?(coerce(a))
  def positive?(a), do: FastDecimal.positive?(coerce(a))
  def negative?(a), do: FastDecimal.negative?(coerce(a))
  def nan?(a), do: FastDecimal.nan?(coerce(a))
  def inf?(a), do: FastDecimal.inf?(coerce(a))
  def finite?(a), do: FastDecimal.finite?(coerce(a))

  def integer?(d) do
    case FastDecimal.normalize(coerce(d)) do
      %FastDecimal{exp: e} when e >= 0 -> true
      _ -> false
    end
  end

  # ---- Conversion ---------------------------------------------------------

  def to_string(a), do: FastDecimal.to_string(coerce(a))
  def to_string(a, format), do: FastDecimal.to_string(coerce(a), format)

  def to_integer(a), do: FastDecimal.to_integer(coerce(a))
  def to_float(a), do: FastDecimal.to_float(coerce(a))

  def normalize(a), do: FastDecimal.normalize(coerce(a))
  defdelegate reduce(a), to: __MODULE__, as: :normalize
end
