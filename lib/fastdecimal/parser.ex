defmodule FastDecimal.Parser do
  @moduledoc false

  # Two parse strategies are implemented here. `parse/1` calls the one that
  # won the head-to-head in `bench/parse.exs`: walk wins on every input
  # shorter than ~25 digits — sub-binary allocation cost is outweighed by
  # tight BEAM dispatch and the JIT's specialization of the inner loop.
  # Split wins only on pathologically long pure-integer strings where
  # :erlang.binary_to_integer's C path dominates.
  #
  # Returns `{:ok, {coef, exp}}` where coef can be:
  #   - an integer (the normal case)
  #   - `:nan` for "NaN"
  #   - `:inf` for "Infinity" / "Inf"
  #   - `:neg_inf` for "-Infinity" / "-Inf"

  @type coef :: integer() | :nan | :inf | :neg_inf

  @spec parse(binary()) :: {:ok, {coef(), integer()}} | :error
  def parse(bin), do: parse_walk(bin)

  # --- Special-value strings (handled before numeric walk) -----------------
  # Literal binary clauses dispatch directly; no impact on the numeric fast path.

  @doc false
  @spec parse_walk(binary()) :: {:ok, {coef(), integer()}} | :error
  def parse_walk(<<"NaN">>), do: {:ok, {:nan, 0}}
  def parse_walk(<<"nan">>), do: {:ok, {:nan, 0}}
  def parse_walk(<<"Infinity">>), do: {:ok, {:inf, 0}}
  def parse_walk(<<"Inf">>), do: {:ok, {:inf, 0}}
  def parse_walk(<<"inf">>), do: {:ok, {:inf, 0}}
  def parse_walk(<<"+Infinity">>), do: {:ok, {:inf, 0}}
  def parse_walk(<<"+Inf">>), do: {:ok, {:inf, 0}}
  def parse_walk(<<"-Infinity">>), do: {:ok, {:neg_inf, 0}}
  def parse_walk(<<"-Inf">>), do: {:ok, {:neg_inf, 0}}
  def parse_walk(<<"-inf">>), do: {:ok, {:neg_inf, 0}}

  # --- Numeric walk --------------------------------------------------------

  def parse_walk(<<"-", rest::binary>>) do
    case parse_int(rest, 0, 0, false) do
      {:ok, {c, e}} when is_integer(c) -> {:ok, {-c, e}}
      _ -> :error
    end
  end

  def parse_walk(<<"+", rest::binary>>), do: parse_int(rest, 0, 0, false)
  def parse_walk(bin) when is_binary(bin), do: parse_int(bin, 0, 0, false)

  defp parse_int(<<d, rest::binary>>, acc, _digits, _seen?) when d >= ?0 and d <= ?9 do
    parse_int(rest, acc * 10 + (d - ?0), 0, true)
  end

  defp parse_int(<<".", rest::binary>>, acc, _digits, true),
    do: parse_frac(rest, acc, 0, true, true)

  defp parse_int(<<".", rest::binary>>, acc, _digits, false),
    do: parse_frac(rest, acc, 0, false, true)

  # Exponent after integer part: "1e10", "5E-3"
  defp parse_int(<<e, rest::binary>>, acc, _digits, true) when e == ?e or e == ?E do
    parse_exp(rest, acc, 0)
  end

  defp parse_int(<<>>, acc, _digits, true), do: {:ok, {acc, 0}}
  defp parse_int(_, _acc, _digits, _seen?), do: :error

  defp parse_frac(<<d, rest::binary>>, acc, frac_digits, _seen_int?, _seen_frac?)
       when d >= ?0 and d <= ?9 do
    parse_frac(rest, acc * 10 + (d - ?0), frac_digits + 1, true, true)
  end

  # Exponent after fraction: "1.23e10", "0.5e-3"
  defp parse_frac(<<e, rest::binary>>, acc, frac_digits, true, true)
       when e == ?e or e == ?E do
    parse_exp(rest, acc, -frac_digits)
  end

  defp parse_frac(<<>>, acc, frac_digits, true, _), do: {:ok, {acc, -frac_digits}}
  defp parse_frac(_, _acc, _frac, _seen_int?, _seen_frac?), do: :error

  # --- Exponent (signed decimal int after 'e' or 'E') ----------------------

  # SECURITY: reject scientific-notation inputs with extreme exponents.
  # Catches CVE-2026-32686-class DoS attempts at the parser boundary so
  # malicious values like "1e1000000000" from untrusted input never make
  # it into a `%FastDecimal{}`. 65,535 is well above any practical use
  # (IEEE 754 decimal128's emax is 6,144) but small enough that arithmetic
  # on the resulting value stays in the fast path.
  @max_parse_exponent 65_535

  defp parse_exp(<<"-", rest::binary>>, mantissa, base_exp),
    do: parse_exp_digits(rest, mantissa, base_exp, -1, 0, false)

  defp parse_exp(<<"+", rest::binary>>, mantissa, base_exp),
    do: parse_exp_digits(rest, mantissa, base_exp, 1, 0, false)

  defp parse_exp(bin, mantissa, base_exp),
    do: parse_exp_digits(bin, mantissa, base_exp, 1, 0, false)

  # Early-exit the accumulator if it crosses the limit. Stops a multi-million
  # digit acc loop before it can cause its own (smaller) DoS just parsing.
  defp parse_exp_digits(_, _, _, _, acc, _) when acc > @max_parse_exponent, do: :error

  defp parse_exp_digits(<<d, rest::binary>>, mantissa, base_exp, sign, acc, _seen?)
       when d >= ?0 and d <= ?9 do
    parse_exp_digits(rest, mantissa, base_exp, sign, acc * 10 + (d - ?0), true)
  end

  defp parse_exp_digits(<<>>, mantissa, base_exp, sign, acc, true) do
    final_exp = base_exp + sign * acc

    if final_exp > @max_parse_exponent or final_exp < -@max_parse_exponent do
      :error
    else
      {:ok, {mantissa, final_exp}}
    end
  end

  defp parse_exp_digits(_, _mantissa, _base_exp, _sign, _acc, _seen?), do: :error

  # --- Strategy B (kept for benchmarking, see bench/parse.exs) -------------

  @doc false
  @spec parse_split(binary()) :: {:ok, {integer(), integer()}} | :error
  def parse_split(<<"-", rest::binary>>) do
    case parse_split_body(rest) do
      {:ok, {c, e}} when is_integer(c) -> {:ok, {-c, e}}
      _ -> :error
    end
  end

  def parse_split(<<"+", rest::binary>>), do: parse_split_body(rest)
  def parse_split(<<>>), do: :error
  def parse_split(bin) when is_binary(bin), do: parse_split_body(bin)

  defp parse_split_body(bin) do
    case :binary.match(bin, ".") do
      :nomatch ->
        try_int(bin, 0)

      {pos, 1} ->
        int_size = pos
        <<int_part::binary-size(int_size), ?., frac_part::binary>> = bin
        frac_size = byte_size(frac_part)

        cond do
          int_part == "" and frac_part == "" ->
            :error

          true ->
            try_int_pair(int_part, frac_part, frac_size)
        end
    end
  end

  defp try_int(<<>>, _exp), do: :error

  defp try_int(bin, exp) do
    try do
      {:ok, {:erlang.binary_to_integer(bin), exp}}
    rescue
      ArgumentError -> :error
    end
  end

  defp try_int_pair(int_part, frac_part, frac_size) do
    try do
      int_val =
        case int_part do
          "" -> 0
          _ -> :erlang.binary_to_integer(int_part)
        end

      frac_val =
        case frac_part do
          "" -> 0
          _ -> :erlang.binary_to_integer(frac_part)
        end

      if frac_val < 0 do
        :error
      else
        coef = int_val * pow10(frac_size) + frac_val
        {:ok, {coef, -frac_size}}
      end
    rescue
      ArgumentError -> :error
    end
  end

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
  defp pow10(n) when n > 0, do: 10 * pow10(n - 1)
end
