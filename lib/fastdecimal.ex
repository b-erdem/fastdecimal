defmodule FastDecimal do
  @moduledoc """
  Fast arbitrary-precision decimal arithmetic for Elixir.

  A decimal is represented as `coef * 10^exp` where `coef` is a BEAM integer
  (sign carried inline) and `exp` is an integer exponent. Operations work on
  raw integers in the hot path; values that exceed 60-bit immediate ints
  promote to BEAM bignums automatically.

  ## Design: exact arithmetic, explicit precision

  Unlike `Decimal`, FastDecimal does **not** maintain an implicit per-process
  precision context. `add`, `sub`, and `mult` are mathematically exact — the
  result coefficient grows to whatever size is needed. Only `div/3` takes a
  precision argument, because division is the only operation that can produce
  a non-terminating decimal.

  If you want bounded precision after an arithmetic chain, call `round/2` or
  `normalize/1` explicitly. Trading implicit context for explicit calls is
  faster (no process-dict lookup per op) and easier to reason about.

  ## Construction

      iex> FastDecimal.new("1.23")
      %FastDecimal{coef: 123, exp: -2}

      iex> FastDecimal.new(123, -2)
      %FastDecimal{coef: 123, exp: -2}

  Use the `~d` sigil for compile-time literals (zero runtime parse cost):

      import FastDecimal
      ~d"1.23"   # => %FastDecimal{coef: 123, exp: -2}

  ## Arithmetic

      iex> FastDecimal.add(FastDecimal.new("1.23"), FastDecimal.new("4.567"))
      %FastDecimal{coef: 5797, exp: -3}

      iex> FastDecimal.div(FastDecimal.new("10"), FastDecimal.new("3"), precision: 5)
      %FastDecimal{coef: 33333, exp: -4}

  ## Comparison

      iex> FastDecimal.compare(FastDecimal.new("1.10"), FastDecimal.new("1.1"))
      :eq

      iex> FastDecimal.equal?(FastDecimal.new("1.10"), FastDecimal.new("1.1"))
      true
  """

  alias FastDecimal.Parser

  @enforce_keys [:coef, :exp]
  defstruct [:coef, :exp]

  @type coef :: integer() | :nan | :inf | :neg_inf
  @type t :: %__MODULE__{coef: coef(), exp: integer()}
  @type rounding_mode :: :half_even | :half_up | :half_down | :down | :up | :floor | :ceiling

  # Security: exponent-amplification DoS bound. CVE-2026-32686 (in `decimal`)
  # showed that compact inputs like `1e1000000000` could force multi-second
  # expansions or OOM at materialization time (to_string, add-with-huge-gap,
  # etc). Decimal v2.4.0 mitigated by sticky-bit precision-bounded scaling;
  # we cap `pow10/1` at @max_safe_pow10 instead, which catches the same
  # attack vector at a single chokepoint. 100_000 keeps every legitimate
  # use case in the fast path (fintech tops out around exp ±30, IEEE 754
  # decimal128 tops at ±6144) while killing the runaway path.
  @max_safe_pow10 100_000

  # Note: the parser has its own `@max_parse_exponent` constant (matching
  # this module's intent) — it lives there so it can early-exit during
  # digit accumulation. Defense in depth: even if parsing slipped a huge
  # value through, the `pow10` cap above would still catch downstream ops.

  # to_string output cap. Refuse to materialize binaries larger than this.
  # 1 MB is way above any reasonable printed-decimal size.
  @max_to_string_bytes 1_048_576

  # We can't use `%__MODULE__{}` in module attributes (struct not yet defined
  # at that point). Use the raw map form — it's identical at runtime and
  # pattern-matches as a FastDecimal struct.
  @nan %{__struct__: __MODULE__, coef: :nan, exp: 0}
  @inf %{__struct__: __MODULE__, coef: :inf, exp: 0}
  @neg_inf %{__struct__: __MODULE__, coef: :neg_inf, exp: 0}

  @compile {:inline,
            new: 1,
            new: 2,
            add: 2,
            sub: 2,
            mult: 2,
            negate: 1,
            abs: 1,
            zero?: 1,
            positive?: 1,
            negative?: 1,
            compare: 2,
            equal?: 2,
            nan?: 1,
            inf?: 1,
            finite?: 1,
            pow10: 1}

  # ---- Guard-safe macro ---------------------------------------------------

  @doc """
  Guard-safe predicate. True when the argument is a `%FastDecimal{}` struct.

      defmodule MyMod do
        require FastDecimal

        def total(d) when FastDecimal.is_decimal(d) do
          # ...
        end
      end

  Mirrors `Decimal.Macros.is_decimal/1` so it can be drop-in-substituted.
  """
  defmacro is_decimal(value) do
    quote do
      is_struct(unquote(value), FastDecimal)
    end
  end

  # ---- Special-value constants --------------------------------------------

  @doc "Returns the NaN sentinel value."
  @spec nan() :: t()
  def nan, do: @nan

  @doc "Returns the +∞ sentinel value."
  @spec inf() :: t()
  def inf, do: @inf

  @doc "Returns the -∞ sentinel value."
  @spec neg_inf() :: t()
  def neg_inf, do: @neg_inf

  # ---- Construction --------------------------------------------------------

  @spec new(String.t() | integer()) :: t()
  def new(int) when is_integer(int), do: %__MODULE__{coef: int, exp: 0}

  def new(str) when is_binary(str) do
    case Parser.parse(str) do
      {:ok, {coef, exp}} -> %__MODULE__{coef: coef, exp: exp}
      :error -> raise ArgumentError, "could not parse #{inspect(str)} as a FastDecimal"
    end
  end

  @spec new(integer(), integer()) :: t()
  def new(coef, exp) when is_integer(coef) and is_integer(exp),
    do: %__MODULE__{coef: coef, exp: exp}

  @spec from_integer(integer()) :: t()
  def from_integer(int) when is_integer(int), do: %__MODULE__{coef: int, exp: 0}

  @doc """
  Convert an Elixir float to a FastDecimal via `Float.to_string/1`. The result
  is the decimal value that `Float.to_string/1` would print for the float —
  not the exact rational represented by the IEEE 754 bits.

      iex> FastDecimal.from_float(1.5)
      %FastDecimal{coef: 15, exp: -1}

      iex> FastDecimal.from_float(0.1)
      %FastDecimal{coef: 1, exp: -1}

  Mirrors `Decimal.from_float/1` for drop-in compatibility. For literal-float
  inputs in code, prefer the `~d` sigil — it parses at compile time with no
  runtime cost.
  """
  @spec from_float(float()) :: t()
  def from_float(float) when is_float(float) do
    case parse(Float.to_string(float)) do
      {:ok, d} -> d
      :error -> raise ArgumentError, "could not convert #{inspect(float)} to a FastDecimal"
    end
  end

  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(str) when is_binary(str) do
    case Parser.parse(str) do
      {:ok, {coef, exp}} -> {:ok, %__MODULE__{coef: coef, exp: exp}}
      :error -> :error
    end
  end

  # ---- Sigil ---------------------------------------------------------------

  @doc """
  Compile-time literal sigil. `~d"1.23"` becomes a `%FastDecimal{}` at compile
  time, paying zero parse cost at runtime.

  Use by importing: `import FastDecimal`, then `~d"1.23"`.
  """
  defmacro sigil_d({:<<>>, _, [string]}, _modifiers) when is_binary(string) do
    case Parser.parse(string) do
      {:ok, {coef, exp}} ->
        quote do
          %FastDecimal{coef: unquote(coef), exp: unquote(exp)}
        end

      :error ->
        raise ArgumentError, "could not parse #{inspect(string)} as a FastDecimal"
    end
  end

  defmacro sigil_d({:<<>>, _, _parts}, _modifiers) do
    raise ArgumentError, "~d sigil only supports literal binaries (no interpolation)"
  end

  # ---- Arithmetic ----------------------------------------------------------

  # Implementation note: fast path is gated with `is_integer(c1) and is_integer(c2)`
  # so the cheap-int case stays at ~42 ns. Operations involving NaN/Inf fall
  # through to the `_special` clauses, which are correct but slower.
  #
  # Earlier we tried `%{a | coef: c1 + c2}` (Elixir's strict-update form) to
  # coax BEAM into emitting `put_map_exact` instead of `put_map_assoc`. The
  # bytecode change happened but wall-time didn't move — actually got 1%
  # slower in the head-to-head. BEAMAsm has tight impls of both ops for tiny
  # structs. We use the literal-struct form because every field is explicit
  # at the call site.

  @spec add(t(), t()) :: t()
  def add(%__MODULE__{coef: c1, exp: e}, %__MODULE__{coef: c2, exp: e})
      when is_integer(c1) and is_integer(c2),
      do: %__MODULE__{coef: c1 + c2, exp: e}

  def add(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2) and e1 < e2,
      do: %__MODULE__{coef: c1 + c2 * pow10(e2 - e1), exp: e1}

  def add(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2),
      do: %__MODULE__{coef: c1 * pow10(e1 - e2) + c2, exp: e2}

  def add(a, b), do: add_special(a, b)

  defp add_special(%__MODULE__{coef: :nan}, _), do: @nan
  defp add_special(_, %__MODULE__{coef: :nan}), do: @nan
  defp add_special(%__MODULE__{coef: :inf}, %__MODULE__{coef: :neg_inf}), do: @nan
  defp add_special(%__MODULE__{coef: :neg_inf}, %__MODULE__{coef: :inf}), do: @nan
  defp add_special(%__MODULE__{coef: :inf}, _), do: @inf
  defp add_special(_, %__MODULE__{coef: :inf}), do: @inf
  defp add_special(%__MODULE__{coef: :neg_inf}, _), do: @neg_inf
  defp add_special(_, %__MODULE__{coef: :neg_inf}), do: @neg_inf

  @spec sub(t(), t()) :: t()
  def sub(%__MODULE__{coef: c1, exp: e}, %__MODULE__{coef: c2, exp: e})
      when is_integer(c1) and is_integer(c2),
      do: %__MODULE__{coef: c1 - c2, exp: e}

  def sub(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2) and e1 < e2,
      do: %__MODULE__{coef: c1 - c2 * pow10(e2 - e1), exp: e1}

  def sub(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2),
      do: %__MODULE__{coef: c1 * pow10(e1 - e2) - c2, exp: e2}

  def sub(a, b), do: add_special(a, negate(b))

  @spec mult(t(), t()) :: t()
  def mult(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2),
      do: %__MODULE__{coef: c1 * c2, exp: e1 + e2}

  def mult(a, b), do: mult_special(a, b)

  defp mult_special(%__MODULE__{coef: :nan}, _), do: @nan
  defp mult_special(_, %__MODULE__{coef: :nan}), do: @nan
  defp mult_special(%__MODULE__{coef: 0}, %__MODULE__{coef: :inf}), do: @nan
  defp mult_special(%__MODULE__{coef: 0}, %__MODULE__{coef: :neg_inf}), do: @nan
  defp mult_special(%__MODULE__{coef: :inf}, %__MODULE__{coef: 0}), do: @nan
  defp mult_special(%__MODULE__{coef: :neg_inf}, %__MODULE__{coef: 0}), do: @nan
  defp mult_special(%__MODULE__{coef: :inf}, b), do: if(negative?(b), do: @neg_inf, else: @inf)

  defp mult_special(%__MODULE__{coef: :neg_inf}, b),
    do: if(negative?(b), do: @inf, else: @neg_inf)

  defp mult_special(a, %__MODULE__{coef: :inf}), do: if(negative?(a), do: @neg_inf, else: @inf)

  defp mult_special(a, %__MODULE__{coef: :neg_inf}),
    do: if(negative?(a), do: @inf, else: @neg_inf)

  defdelegate multiply(a, b), to: __MODULE__, as: :mult

  @doc """
  Division with configurable precision and rounding.

  Options:
    * `:precision` — number of significant digits to keep in the result (default `28`)
    * `:rounding` — `:half_even` (default, banker's), `:half_up`, `:half_down`,
      `:down`, `:up`, `:floor`, `:ceiling`
  """
  @spec div(t(), t(), keyword()) :: t()
  def div(a, b, opts \\ [])

  def div(_, %__MODULE__{coef: 0}, _opts), do: raise(ArithmeticError, "decimal division by zero")

  def div(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2}, opts)
      when is_integer(c1) and is_integer(c2) do
    precision = Keyword.get(opts, :precision, 28)
    mode = Keyword.get(opts, :rounding, :half_even)

    # Shift c1 so the integer quotient `c1 * 10^shift / c2` has at least
    # precision + 1 digits — the extra "scratch" digit is used to round.
    # The natural quotient digit count is digits(c1) - digits(c2) + {0,1},
    # so we pick a generous shift and trim down to exactly precision + 1.
    shift = precision + 1 + digits(Kernel.abs(c2)) - digits(Kernel.abs(c1))
    shift = if shift < 0, do: 0, else: shift

    dividend = c1 * pow10(shift)
    quot = Kernel.div(dividend, c2)
    rem = Kernel.rem(dividend, c2)

    # Trim down to exactly precision + 1 digits in the quotient, folding any
    # trimmed digits into the "has tail" signal for rounding.
    quot_digits = digits(Kernel.abs(quot))
    excess = quot_digits - (precision + 1)

    {quot, has_tail, shift} =
      if excess > 0 do
        divisor = pow10(excess)
        trimmed_nonzero = Kernel.rem(quot, divisor) != 0
        {Kernel.div(quot, divisor), trimmed_nonzero or rem != 0, shift - excess}
      else
        {quot, rem != 0, shift}
      end

    rounded = round_div(quot, has_tail, mode)
    %__MODULE__{coef: rounded, exp: e1 - e2 - shift + 1}
  end

  def div(a, b, _opts), do: div_special(a, b)

  defp div_special(%__MODULE__{coef: :nan}, _), do: @nan
  defp div_special(_, %__MODULE__{coef: :nan}), do: @nan
  defp div_special(%__MODULE__{coef: :inf}, %__MODULE__{coef: :inf}), do: @nan
  defp div_special(%__MODULE__{coef: :inf}, %__MODULE__{coef: :neg_inf}), do: @nan
  defp div_special(%__MODULE__{coef: :neg_inf}, %__MODULE__{coef: :inf}), do: @nan
  defp div_special(%__MODULE__{coef: :neg_inf}, %__MODULE__{coef: :neg_inf}), do: @nan
  defp div_special(%__MODULE__{coef: :inf}, b), do: if(negative?(b), do: @neg_inf, else: @inf)
  defp div_special(%__MODULE__{coef: :neg_inf}, b), do: if(negative?(b), do: @inf, else: @neg_inf)
  defp div_special(_, %__MODULE__{coef: :inf}), do: %__MODULE__{coef: 0, exp: 0}
  defp div_special(_, %__MODULE__{coef: :neg_inf}), do: %__MODULE__{coef: 0, exp: 0}

  @doc """
  Integer (truncated) division. Like `Kernel.div/2` for integers — drops the
  fractional part, truncating toward zero. Result always has `exp: 0`.

      iex> FastDecimal.div_int(FastDecimal.new("10.5"), FastDecimal.new("3"))
      %FastDecimal{coef: 3, exp: 0}
  """
  @spec div_int(t(), t()) :: t()
  def div_int(_, %__MODULE__{coef: 0}), do: raise(ArithmeticError, "decimal division by zero")

  def div_int(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2) do
    {ac1, ac2} =
      cond do
        e1 == e2 -> {c1, c2}
        e1 < e2 -> {c1, c2 * pow10(e2 - e1)}
        e1 > e2 -> {c1 * pow10(e1 - e2), c2}
      end

    %__MODULE__{coef: Kernel.div(ac1, ac2), exp: 0}
  end

  def div_int(a, b), do: div_special(a, b)

  @doc """
  Returns `{quotient, remainder}` such that `a == quotient * b + remainder`.
  Quotient is computed by `div_int/2`.

      iex> FastDecimal.div_rem(FastDecimal.new("10"), FastDecimal.new("3"))
      {%FastDecimal{coef: 3, exp: 0}, %FastDecimal{coef: 1, exp: 0}}
  """
  @spec div_rem(t(), t()) :: {t(), t()}
  def div_rem(_, %__MODULE__{coef: 0}), do: raise(ArithmeticError, "decimal division by zero")

  def div_rem(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2) do
    # Direct computation: align coefs to a common exp, then use BEAM's
    # `div` and `rem` BIFs in one pass. Avoids the previous "call div_int,
    # then mult, then sub" three-step approach.
    target_exp = Kernel.min(e1, e2)

    {ac1, ac2} =
      cond do
        e1 == e2 -> {c1, c2}
        e1 < e2 -> {c1, c2 * pow10(e2 - e1)}
        true -> {c1 * pow10(e1 - e2), c2}
      end

    q = Kernel.div(ac1, ac2)
    r = Kernel.rem(ac1, ac2)
    {%__MODULE__{coef: q, exp: 0}, %__MODULE__{coef: r, exp: target_exp}}
  end

  @doc "Remainder of decimal division (same sign as the dividend)."
  @spec rem(t(), t()) :: t()
  def rem(a, b) do
    {_q, r} = div_rem(a, b)
    r
  end

  @doc """
  Square root with configurable precision (default 28 significant digits).

  Newton-Raphson on bigints; converges in ~log(digits) iterations because
  the initial guess uses the number's digit count.

      iex> FastDecimal.sqrt(FastDecimal.new("4"))
      %FastDecimal{coef: 2, exp: 0}

      iex> FastDecimal.sqrt(FastDecimal.new("2"), precision: 10)
      %FastDecimal{coef: 1414213562, exp: -9}
  """
  @spec sqrt(t(), keyword()) :: t()
  def sqrt(decimal, opts \\ [])

  def sqrt(%__MODULE__{coef: :nan}, _), do: @nan
  def sqrt(%__MODULE__{coef: :inf}, _), do: @inf
  def sqrt(%__MODULE__{coef: :neg_inf}, _), do: @nan
  def sqrt(%__MODULE__{coef: 0}, _), do: %__MODULE__{coef: 0, exp: 0}
  def sqrt(%__MODULE__{coef: c}, _) when is_integer(c) and c < 0, do: @nan

  def sqrt(%__MODULE__{coef: c, exp: e}, opts) when is_integer(c) and c > 0 do
    precision = Keyword.get(opts, :precision, 28)

    # Normalize so exponent is even: sqrt(c·10^e) = sqrt(c)·10^(e/2).
    {c, e} = if Kernel.rem(e, 2) == 0, do: {c, e}, else: {c * 10, e - 1}

    # We want the result coefficient to have exactly `precision` digits.
    # Scaling `c` by 10^(2·(precision-1)) puts the isqrt result in that range.
    shift = precision - 1
    scaled = c * pow10(2 * shift)
    root = isqrt(scaled)
    # Normalize to strip trailing zeros (so sqrt(4) reads "2", not "2.000...0").
    normalize(%__MODULE__{coef: root, exp: Kernel.div(e, 2) - shift})
  end

  # `sqrt/2` filters coef: 0 and coef: <0 above, so isqrt is only ever called
  # with `pos_integer()` (specifically `c * pow10(2 * shift) >= 1`). The
  # `isqrt(1)` base case handles the smallest possible input.
  defp isqrt(1), do: 1

  defp isqrt(n) when n > 1 do
    # Initial guess: 10^ceil(digits/2). Good enough that Newton-Raphson
    # converges in a handful of iterations for any input size.
    guess = pow10(Kernel.div(digits(n) + 1, 2))
    isqrt_iter(n, guess)
  end

  defp isqrt_iter(n, x) do
    x_new = Kernel.div(x + Kernel.div(n, x), 2)
    if x_new >= x, do: x, else: isqrt_iter(n, x_new)
  end

  @doc """
  Sum a list of FastDecimals. Equivalent to `Enum.reduce(list, new(0), &add/2)`
  but inlined and recursion-flat. The tight inner loop avoids `Enum`'s anonymous
  function call overhead.
  """
  @spec sum([t()]) :: t()
  # Allocation-free accumulator: walks the list carrying raw {coef, exp} —
  # only builds the final %FastDecimal{} struct at the end. For sum of N
  # values this is N-1 fewer struct allocations than the pairwise-add loop,
  # saving ~5 kB of garbage on a 100-element sum.
  #
  # Special values (NaN, Inf) trip the fast path's `is_integer` guard and
  # fall through to the pairwise slow path.
  def sum([]), do: %__MODULE__{coef: 0, exp: 0}

  def sum([%__MODULE__{coef: c, exp: e} | rest]) when is_integer(c),
    do: sum_fast(rest, c, e)

  def sum([first | rest]), do: sum_slow(rest, first)

  defp sum_fast([], acc, exp), do: %__MODULE__{coef: acc, exp: exp}

  defp sum_fast([%__MODULE__{coef: c, exp: e} | rest], acc, exp)
       when is_integer(c) and e == exp,
       do: sum_fast(rest, acc + c, exp)

  defp sum_fast([%__MODULE__{coef: c, exp: e} | rest], acc, exp)
       when is_integer(c) and exp < e,
       do: sum_fast(rest, acc + c * pow10(e - exp), exp)

  defp sum_fast([%__MODULE__{coef: c, exp: e} | rest], acc, exp)
       when is_integer(c),
       do: sum_fast(rest, acc * pow10(exp - e) + c, e)

  defp sum_fast(list, acc, exp),
    # First special value seen — switch to the pairwise add path which knows
    # how to propagate NaN/Inf correctly.
    do: sum_slow(list, %__MODULE__{coef: acc, exp: exp})

  defp sum_slow([], acc), do: acc
  defp sum_slow([h | t], acc), do: sum_slow(t, add(acc, h))

  @doc """
  Product of a list of FastDecimals.
  """
  @spec product([t()]) :: t()
  # Same trick as `sum/1`: accumulate raw coef * exp pairs, build struct at end.
  def product([]), do: %__MODULE__{coef: 1, exp: 0}

  def product([%__MODULE__{coef: c, exp: e} | rest]) when is_integer(c),
    do: product_fast(rest, c, e)

  def product([first | rest]), do: product_slow(rest, first)

  defp product_fast([], acc, exp), do: %__MODULE__{coef: acc, exp: exp}

  defp product_fast([%__MODULE__{coef: c, exp: e} | rest], acc, exp)
       when is_integer(c),
       do: product_fast(rest, acc * c, exp + e)

  defp product_fast(list, acc, exp),
    do: product_slow(list, %__MODULE__{coef: acc, exp: exp})

  defp product_slow([], acc), do: acc
  defp product_slow([h | t], acc), do: product_slow(t, mult(acc, h))

  @spec negate(t()) :: t()
  def negate(%__MODULE__{coef: c, exp: e}) when is_integer(c),
    do: %__MODULE__{coef: -c, exp: e}

  def negate(%__MODULE__{coef: :inf}), do: @neg_inf
  def negate(%__MODULE__{coef: :neg_inf}), do: @inf
  def negate(%__MODULE__{coef: :nan}), do: @nan

  @spec abs(t()) :: t()
  def abs(%__MODULE__{coef: c, exp: e}) when is_integer(c),
    do: %__MODULE__{coef: Kernel.abs(c), exp: e}

  def abs(%__MODULE__{coef: :neg_inf}), do: @inf
  def abs(%__MODULE__{coef: :inf}), do: @inf
  def abs(%__MODULE__{coef: :nan}), do: @nan

  @spec min(t(), t()) :: t()
  def min(a, b) do
    case compare(a, b) do
      :gt -> b
      _ -> a
    end
  end

  @spec max(t(), t()) :: t()
  def max(a, b) do
    case compare(a, b) do
      :lt -> b
      _ -> a
    end
  end

  # ---- Comparison & predicates --------------------------------------------

  # Fast path: both coefficients are integers (the 99% case).
  # Special values (NaN / ±Inf) fall through to compare_special/2.

  @spec compare(t(), t()) :: :lt | :eq | :gt | :nan
  def compare(%__MODULE__{coef: c1, exp: e}, %__MODULE__{coef: c2, exp: e})
      when is_integer(c1) and is_integer(c2) do
    cond do
      c1 < c2 -> :lt
      c1 > c2 -> :gt
      true -> :eq
    end
  end

  def compare(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2) and e1 < e2 do
    aligned = c2 * pow10(e2 - e1)

    cond do
      c1 < aligned -> :lt
      c1 > aligned -> :gt
      true -> :eq
    end
  end

  def compare(%__MODULE__{coef: c1, exp: e1}, %__MODULE__{coef: c2, exp: e2})
      when is_integer(c1) and is_integer(c2) do
    aligned = c1 * pow10(e1 - e2)

    cond do
      aligned < c2 -> :lt
      aligned > c2 -> :gt
      true -> :eq
    end
  end

  def compare(a, b), do: compare_special(a, b)

  # Special-value comparison: any NaN ⇒ :nan; ±Inf ordered as expected.
  defp compare_special(%__MODULE__{coef: :nan}, _), do: :nan
  defp compare_special(_, %__MODULE__{coef: :nan}), do: :nan
  defp compare_special(%__MODULE__{coef: :inf}, %__MODULE__{coef: :inf}), do: :eq
  defp compare_special(%__MODULE__{coef: :neg_inf}, %__MODULE__{coef: :neg_inf}), do: :eq
  defp compare_special(%__MODULE__{coef: :inf}, _), do: :gt
  defp compare_special(_, %__MODULE__{coef: :inf}), do: :lt
  defp compare_special(%__MODULE__{coef: :neg_inf}, _), do: :lt
  defp compare_special(_, %__MODULE__{coef: :neg_inf}), do: :gt

  @doc """
  Returns true if both decimals compare as equal. NaN never compares equal to
  anything (matches IEEE 754 behavior for floating-point NaN).
  """
  @spec equal?(t(), t()) :: boolean()
  # Identical-struct short-circuit. Saves the compare/2 call when both args
  # have the same coef and exp (common for `equal?(a, a)` checks and for
  # comparing a stored value to a fresh literal that landed in the same
  # representation).
  def equal?(%__MODULE__{coef: c, exp: e}, %__MODULE__{coef: c, exp: e})
      when is_integer(c),
      do: true

  def equal?(a, b), do: compare(a, b) == :eq

  @spec lt?(t(), t()) :: boolean()
  def lt?(%__MODULE__{coef: c, exp: e}, %__MODULE__{coef: c, exp: e})
      when is_integer(c),
      do: false

  def lt?(a, b), do: compare(a, b) == :lt

  @spec gt?(t(), t()) :: boolean()
  def gt?(%__MODULE__{coef: c, exp: e}, %__MODULE__{coef: c, exp: e})
      when is_integer(c),
      do: false

  def gt?(a, b), do: compare(a, b) == :gt

  @spec zero?(t()) :: boolean()
  def zero?(%__MODULE__{coef: 0}), do: true
  def zero?(%__MODULE__{}), do: false

  @spec positive?(t()) :: boolean()
  def positive?(%__MODULE__{coef: c}) when is_integer(c), do: c > 0
  def positive?(%__MODULE__{coef: :inf}), do: true
  def positive?(%__MODULE__{}), do: false

  @spec negative?(t()) :: boolean()
  def negative?(%__MODULE__{coef: c}) when is_integer(c), do: c < 0
  def negative?(%__MODULE__{coef: :neg_inf}), do: true
  def negative?(%__MODULE__{}), do: false

  @doc "Returns true if the value is NaN (not a number)."
  @spec nan?(t()) :: boolean()
  def nan?(%__MODULE__{coef: :nan}), do: true
  def nan?(%__MODULE__{}), do: false

  @doc "Returns true if the value is +∞ or -∞."
  @spec inf?(t()) :: boolean()
  def inf?(%__MODULE__{coef: :inf}), do: true
  def inf?(%__MODULE__{coef: :neg_inf}), do: true
  def inf?(%__MODULE__{}), do: false

  @doc "Returns true if the value is a finite number (not NaN, not infinity)."
  @spec finite?(t()) :: boolean()
  def finite?(%__MODULE__{coef: c}) when is_integer(c), do: true
  def finite?(%__MODULE__{}), do: false

  # ---- Rounding / normalization -------------------------------------------

  @doc """
  Round to `places` decimal places using the given rounding mode.

  Default: 0 places, `:half_even` (banker's rounding).

  Supported modes: `:half_even`, `:half_up`, `:half_down`, `:down`, `:up`,
  `:floor`, `:ceiling`.

      iex> FastDecimal.round(FastDecimal.new("1.235"), 2)
      %FastDecimal{coef: 124, exp: -2}

      iex> FastDecimal.round(FastDecimal.new("1.236"), 2, :down)
      %FastDecimal{coef: 123, exp: -2}

      iex> FastDecimal.round(FastDecimal.new("123.456"), -1)
      %FastDecimal{coef: 12, exp: 1}
  """
  @spec round(t(), integer(), rounding_mode()) :: t()
  def round(decimal, places \\ 0, mode \\ :half_even)

  def round(%__MODULE__{coef: :nan} = nan, _places, _mode), do: nan
  def round(%__MODULE__{coef: :inf} = inf, _places, _mode), do: inf
  def round(%__MODULE__{coef: :neg_inf} = neg_inf, _places, _mode), do: neg_inf

  def round(%__MODULE__{coef: c, exp: e} = d, places, _mode)
      when is_integer(c) and e >= -places do
    # Already at or above target precision; nothing to drop.
    d
  end

  def round(%__MODULE__{coef: c, exp: e}, places, mode) when is_integer(c) do
    # We need to drop `-e - places` digits from the coefficient.
    excess = -e - places
    # Leave one scratch digit for round_div to handle.
    pre_div = pow10(excess - 1)
    pre_quot = Kernel.div(c, pre_div)
    pre_rem = Kernel.rem(c, pre_div)
    rounded = round_div(pre_quot, pre_rem != 0, mode)
    %__MODULE__{coef: rounded, exp: -places}
  end

  # ---- Conversion ---------------------------------------------------------

  @doc """
  Soft parse: returns `{:ok, t()}` or `:error` without raising. Accepts the
  same inputs as `new/1` plus existing `FastDecimal` and `Decimal` structs.

  This is what Ecto's `Ecto.Type` machinery calls — exposing it directly
  makes user code that needs "try to coerce, otherwise complain" pleasant.
  """
  @spec cast(t() | integer() | binary() | Decimal.t() | float() | nil) ::
          {:ok, t()} | :error
  def cast(%__MODULE__{} = d), do: {:ok, d}
  def cast(nil), do: :error
  def cast(int) when is_integer(int), do: {:ok, %__MODULE__{coef: int, exp: 0}}
  def cast(str) when is_binary(str), do: parse(str)
  def cast(float) when is_float(float), do: parse(Float.to_string(float))

  def cast(%Decimal{sign: 1, coef: c, exp: e}) when is_integer(c),
    do: {:ok, %__MODULE__{coef: c, exp: e}}

  def cast(%Decimal{sign: -1, coef: c, exp: e}) when is_integer(c),
    do: {:ok, %__MODULE__{coef: -c, exp: e}}

  def cast(%Decimal{coef: :NaN}), do: {:ok, @nan}
  def cast(%Decimal{coef: :inf, sign: 1}), do: {:ok, @inf}
  def cast(%Decimal{coef: :inf, sign: -1}), do: {:ok, @neg_inf}
  def cast(_), do: :error

  @doc """
  Strip trailing zeros from the coefficient, raising the exponent.
  `~d"1.10"` (coef=110, exp=-2) becomes `~d"1.1"` (coef=11, exp=-1).
  """
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{coef: c} = d) when not is_integer(c), do: d
  def normalize(%__MODULE__{coef: 0}), do: %__MODULE__{coef: 0, exp: 0}

  def normalize(%__MODULE__{coef: c, exp: e}) do
    {c, e} = strip_trailing_zeros(c, e)
    %__MODULE__{coef: c, exp: e}
  end

  defp strip_trailing_zeros(c, e) do
    case Kernel.rem(c, 10) do
      0 -> strip_trailing_zeros(Kernel.div(c, 10), e + 1)
      _ -> {c, e}
    end
  end

  @typedoc "Output format for `to_string/2`. `:normal` is the default."
  @type to_string_format :: :normal | :scientific | :raw | :xsd

  @doc """
  Format a decimal as a string. `format` defaults to `:normal`.

    * `:normal` — `"1234.5678"`, `"0.001"`, `"123"` (decimal-point form when
      there are fractional digits, plain integer otherwise)
    * `:scientific` — `"1.2345678E+3"` (one digit before decimal, signed `E`
      exponent). Matches Decimal's `:scientific` format.
    * `:raw` — `"1234E-5"` (raw coefficient + `E` + raw exponent). Useful for
      debugging the internal representation.
    * `:xsd` — XML Schema canonical decimal form. Same as `:normal` for our
      representation since we don't use scientific in XSD.

  Special values (`NaN`, `Infinity`, `-Infinity`) print the same in every format.
  """
  @spec to_string(t(), to_string_format()) :: String.t()
  def to_string(decimal, format \\ :normal)

  def to_string(%__MODULE__{coef: :nan}, _), do: "NaN"
  def to_string(%__MODULE__{coef: :inf}, _), do: "Infinity"
  def to_string(%__MODULE__{coef: :neg_inf}, _), do: "-Infinity"

  def to_string(%__MODULE__{coef: 0, exp: e}, :normal) when e >= 0, do: "0"

  def to_string(%__MODULE__{coef: 0, exp: e}, :normal) when e < 0,
    do: "0." <> safe_zeros(-e)

  def to_string(%__MODULE__{coef: c, exp: 0}, :normal), do: Integer.to_string(c)

  def to_string(%__MODULE__{coef: c, exp: e}, :normal) when e > 0 do
    # SECURITY: refuse to materialize >@max_to_string_bytes bytes (CVE-2026-32686
    # class). Caller can use :scientific or :raw format if they need to see the
    # representation of a very-large-exp value.
    digits_count = digits(Kernel.abs(c))

    if digits_count + e > @max_to_string_bytes do
      raise_to_string_too_big(digits_count + e)
    end

    IO.iodata_to_binary([Integer.to_string(c), :binary.copy("0", e)])
  end

  # Note: in this code path we use `Integer.to_string/1` rather than
  # `:erlang.integer_to_binary/1`. Standalone the BIF is ~28% faster, but
  # inside this function-call shape `Integer.to_string` measured 7-10% faster
  # — looks like BEAM's JIT does something nicer for the Elixir wrapper here
  # (possibly inlining the call site). Bench/disasm and you'll see.
  #
  # Earlier I also tried bit-syntax `<<sign::binary, ...>>` to avoid the
  # iolist cons cells; measured ~20% SLOWER. `iodata_to_binary` is a BIF
  # that pre-computes total size and allocates once. Iolist stays.
  def to_string(%__MODULE__{coef: c, exp: e}, :normal) when e < 0 do
    {sign, abs_c} = if c < 0, do: {"-", -c}, else: {"", c}
    s = Integer.to_string(abs_c)
    digits = byte_size(s)
    shift = -e

    cond do
      digits > shift ->
        split_at = digits - shift
        # `binary_part` is a BIF that returns a sub-binary reference without
        # going through the bit-syntax matcher. Measured ~5% faster than the
        # `<<int::binary-size(N), frac::binary>>` pattern match here.
        IO.iodata_to_binary([
          sign,
          binary_part(s, 0, split_at),
          ?.,
          binary_part(s, split_at, digits - split_at)
        ])

      true ->
        # SECURITY: cap leading-zero pad. See `safe_zeros/1`.
        IO.iodata_to_binary([sign, "0.", safe_zeros(shift - digits), s])
    end
  end

  # ---- :scientific format -------------------------------------------------

  def to_string(%__MODULE__{coef: 0}, :scientific), do: "0E+0"

  # IEEE 754-2008 "to-scientific-string" — the compact form `decimal` also
  # emits. Three branches:
  #   1. exp == 0          → just the digits
  #   2. exp<0, adj>=-6    → normal "decimal point" form (no E notation)
  #   3. otherwise         → "d.dddE+NN" scientific form
  # The threshold (adj >= -6) is from IEEE 754-2008 §5.12.
  def to_string(%__MODULE__{coef: c, exp: e}, :scientific) do
    abs_c = Kernel.abs(c)
    s = :erlang.integer_to_binary(abs_c)
    digits = byte_size(s)
    adj_exp = e + digits - 1

    iodata =
      cond do
        e == 0 ->
          s

        e < 0 and adj_exp >= -6 ->
          # diff = how many "0."-padding zeros to emit (negative ⇒ skip)
          diff = -digits + -e + 1

          if diff > 0 do
            ["0.", :binary.copy("0", diff - 1), s]
          else
            split = digits + e
            [binary_part(s, 0, split), ?., binary_part(s, split, digits - split)]
          end

        true ->
          mantissa =
            if digits == 1 do
              s
            else
              [binary_part(s, 0, 1), ?., binary_part(s, 1, digits - 1)]
            end

          exp_sign = if adj_exp >= 0, do: ?+, else: []
          [mantissa, ?E, exp_sign, :erlang.integer_to_binary(adj_exp)]
      end

    iodata = if c < 0, do: [?-, iodata], else: iodata
    IO.iodata_to_binary(iodata)
  end

  # ---- :raw format (just the internal coef + exp, no formatting) ----------

  def to_string(%__MODULE__{coef: c, exp: 0}, :raw), do: Integer.to_string(c)

  def to_string(%__MODULE__{coef: c, exp: e}, :raw) do
    exp_sign = if e >= 0, do: ?+, else: ?-
    IO.iodata_to_binary([Integer.to_string(c), ?E, exp_sign, Integer.to_string(Kernel.abs(e))])
  end

  # ---- :xsd format (XML Schema canonical decimal — same as :normal here) ---

  def to_string(d, :xsd), do: to_string(d, :normal)

  @spec to_integer(t()) :: integer()
  # Zero short-circuit: 0×10^e is 0 for any e. Skips pow10 allocation and
  # avoids tripping the pow10 cap on `%FastDecimal{coef: 0, exp: -1_000_000}`.
  def to_integer(%__MODULE__{coef: 0}), do: 0
  def to_integer(%__MODULE__{coef: c, exp: 0}), do: c
  def to_integer(%__MODULE__{coef: c, exp: e}) when e > 0, do: c * pow10(e)

  def to_integer(%__MODULE__{coef: c, exp: e}) when e < 0 do
    case Kernel.rem(c, pow10(-e)) do
      0 -> Kernel.div(c, pow10(-e))
      _ -> raise ArgumentError, "FastDecimal is not an integer (has fractional part)"
    end
  end

  @spec to_float(t()) :: float()
  def to_float(%__MODULE__{coef: 0}), do: 0.0
  def to_float(%__MODULE__{coef: c, exp: 0}), do: c * 1.0
  def to_float(%__MODULE__{coef: c, exp: e}) when e > 0, do: c * pow10(e) * 1.0
  def to_float(%__MODULE__{coef: c, exp: e}) when e < 0, do: c / pow10(-e)

  # ---- Internal: round one scratch digit -----------------------------------

  defp round_div(quot, has_tail, mode) do
    scratch = Kernel.rem(quot, 10)
    abs_scratch = Kernel.abs(scratch)
    base = Kernel.div(quot, 10)

    bump =
      case mode do
        :down ->
          0

        :up ->
          if abs_scratch > 0 or has_tail, do: 1, else: 0

        :floor ->
          if (abs_scratch > 0 or has_tail) and quot < 0, do: 1, else: 0

        :ceiling ->
          if (abs_scratch > 0 or has_tail) and quot > 0, do: 1, else: 0

        :half_up ->
          cond do
            abs_scratch > 5 -> 1
            abs_scratch < 5 -> 0
            true -> 1
          end

        :half_down ->
          cond do
            abs_scratch > 5 -> 1
            abs_scratch < 5 -> 0
            has_tail -> 1
            true -> 0
          end

        :half_even ->
          cond do
            abs_scratch > 5 -> 1
            abs_scratch < 5 -> 0
            has_tail -> 1
            true -> if Kernel.rem(Kernel.abs(base), 2) == 1, do: 1, else: 0
          end
      end

    cond do
      bump == 0 -> base
      quot >= 0 -> base + 1
      true -> base - 1
    end
  end

  # SECURITY: bounded zero-padding for to_string. CVE-2026-32686 class
  # vector — a value like `1e1000000000` parses to coef=1, exp=10^9, and
  # to_string normal-form output would `:binary.copy("0", 10^9)`, allocating
  # 1 GB. Cap at @max_to_string_bytes.
  defp safe_zeros(n) when n > @max_to_string_bytes, do: raise_to_string_too_big(n)
  defp safe_zeros(n), do: :binary.copy("0", n)

  defp raise_to_string_too_big(size) do
    raise ArgumentError,
          "to_string(_, :normal) would emit a #{size}-byte string " <>
            "(~#{Kernel.div(size, 1_048_576)} MB). Use `:scientific` or `:raw` format " <>
            "for very-large-exp values, or sanitize input upstream — this is the " <>
            "CVE-2026-32686-class exponent-amplification DoS vector."
  end

  defp digits(0), do: 1
  defp digits(n) when n > 0, do: digits(n, 0)
  defp digits(n, acc) when n < 10, do: acc + 1
  defp digits(n, acc) when n < 100, do: acc + 2
  defp digits(n, acc) when n < 1_000, do: acc + 3
  defp digits(n, acc) when n < 10_000, do: acc + 4
  defp digits(n, acc) when n < 100_000, do: acc + 5
  defp digits(n, acc) when n < 1_000_000, do: acc + 6
  defp digits(n, acc) when n < 10_000_000, do: acc + 7
  defp digits(n, acc) when n < 100_000_000, do: acc + 8
  defp digits(n, acc) when n < 1_000_000_000, do: acc + 9
  defp digits(n, acc), do: digits(Kernel.div(n, 1_000_000_000), acc + 9)

  # Lookup table for pow10(N). The size matters: div/3 at precision 28 calls
  # `pow10(shift)` with shift typically 28-32 (precision + 1 + digits(c2) -
  # digits(c1)). sqrt/2 at precision 50 calls pow10(98). We extend the table
  # so the common-case ops never fall through to the recursive case.
  defp pow10(0), do: 1
  defp pow10(1), do: 10
  defp pow10(2), do: 100
  defp pow10(3), do: 1_000
  defp pow10(4), do: 10_000
  defp pow10(5), do: 100_000
  defp pow10(6), do: 1_000_000
  defp pow10(7), do: 10_000_000
  defp pow10(8), do: 100_000_000
  defp pow10(9), do: 1_000_000_000
  defp pow10(10), do: 10_000_000_000
  defp pow10(11), do: 100_000_000_000
  defp pow10(12), do: 1_000_000_000_000
  defp pow10(13), do: 10_000_000_000_000
  defp pow10(14), do: 100_000_000_000_000
  defp pow10(15), do: 1_000_000_000_000_000
  defp pow10(16), do: 10_000_000_000_000_000
  defp pow10(17), do: 100_000_000_000_000_000
  defp pow10(18), do: 1_000_000_000_000_000_000
  defp pow10(19), do: 10_000_000_000_000_000_000
  defp pow10(20), do: 100_000_000_000_000_000_000
  defp pow10(21), do: 1_000_000_000_000_000_000_000
  defp pow10(22), do: 10_000_000_000_000_000_000_000
  defp pow10(23), do: 100_000_000_000_000_000_000_000
  defp pow10(24), do: 1_000_000_000_000_000_000_000_000
  defp pow10(25), do: 10_000_000_000_000_000_000_000_000
  defp pow10(26), do: 100_000_000_000_000_000_000_000_000
  defp pow10(27), do: 1_000_000_000_000_000_000_000_000_000
  defp pow10(28), do: 10_000_000_000_000_000_000_000_000_000
  defp pow10(29), do: 100_000_000_000_000_000_000_000_000_000
  defp pow10(30), do: 1_000_000_000_000_000_000_000_000_000_000
  defp pow10(31), do: 10_000_000_000_000_000_000_000_000_000_000
  defp pow10(32), do: 100_000_000_000_000_000_000_000_000_000_000
  defp pow10(33), do: 1_000_000_000_000_000_000_000_000_000_000_000
  defp pow10(34), do: 10_000_000_000_000_000_000_000_000_000_000_000
  defp pow10(35), do: 100_000_000_000_000_000_000_000_000_000_000_000
  defp pow10(36), do: 1_000_000_000_000_000_000_000_000_000_000_000_000
  defp pow10(37), do: 10_000_000_000_000_000_000_000_000_000_000_000_000
  defp pow10(38), do: 100_000_000_000_000_000_000_000_000_000_000_000_000

  # SECURITY: refuse pow10 with absurdly large `n`. Catches CVE-2026-32686-
  # class inputs (`1e1000000` etc) at the chokepoint they ultimately route
  # through — every operation that "materializes" a large-exp value calls
  # pow10(huge_n). Single guard, single point of defense.
  defp pow10(n) when n > @max_safe_pow10 do
    raise ArgumentError,
          "pow10(#{n}) would materialize a #{n}-digit bignum (~#{Kernel.div(n, 1024)} KB). " <>
            "This is far beyond any practical use and is likely a denial-of-service " <>
            "attempt via exponent amplification (CVE-2026-32686 in `decimal`). " <>
            "FastDecimal caps pow10 at #{@max_safe_pow10}. Sanitize inputs before " <>
            "passing them to arithmetic / to_string."
  end

  # Binary exponentiation for n > 38. O(log n) multiplications instead of O(n).
  # Hit by sqrt at precision > ~20 (pow10(2 × shift) with shift = precision - 1).
  defp pow10(n) when n > 38 do
    half = pow10(Kernel.div(n, 2))

    if Kernel.rem(n, 2) == 0 do
      half * half
    else
      half * half * 10
    end
  end
end

defimpl Inspect, for: FastDecimal do
  def inspect(decimal, _opts) do
    "~d\"" <> FastDecimal.to_string(decimal) <> "\""
  end
end

defimpl String.Chars, for: FastDecimal do
  def to_string(decimal), do: FastDecimal.to_string(decimal)
end
