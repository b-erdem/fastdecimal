# Representation experiment: how much does the struct wrapper cost vs a
# raw `{coef, exp}` tuple vs raw integers (no wrapper at all)?
#
# Run with: `mix run bench/representation.exs`
#
# This benchmark answers: "if we gave up the %FastDecimal{} struct for the
# sake of speed, how much would we gain?"
#
# Spoiler from running this: the struct wrapper costs ~10-15% on hot ops.
# That's the price we pay for Inspect/String.Chars protocols, pattern
# matching on `%FastDecimal{}`, and the conventional Elixir feel. We pay it.

defmodule Variants do
  # Tuple representation: {coef, exp}
  def tuple_add({c1, e}, {c2, e}), do: {c1 + c2, e}
  def tuple_add({c1, e1}, {c2, e2}) when e1 < e2, do: {c1 + c2 * pow10(e2 - e1), e1}
  def tuple_add({c1, e1}, {c2, e2}), do: {c1 * pow10(e1 - e2) + c2, e2}

  def tuple_mult({c1, e1}, {c2, e2}), do: {c1 * c2, e1 + e2}

  # Raw integer path: caller passes coef and exp separately. No wrapper at all.
  def raw_add(c1, e1, c2, e2) do
    cond do
      e1 == e2 -> {c1 + c2, e1}
      e1 < e2 -> {c1 + c2 * pow10(e2 - e1), e1}
      true -> {c1 * pow10(e1 - e2) + c2, e2}
    end
  end

  def raw_mult(c1, e1, c2, e2), do: {c1 * c2, e1 + e2}

  defp pow10(0), do: 1
  defp pow10(1), do: 10
  defp pow10(2), do: 100
  defp pow10(3), do: 1_000
  defp pow10(4), do: 10_000
  defp pow10(5), do: 100_000
  defp pow10(6), do: 1_000_000
  defp pow10(n) when n > 0, do: 10 * pow10(n - 1)
end

a_struct = %FastDecimal{coef: 123_456_789, exp: -5}
b_struct = %FastDecimal{coef: 987_654_321, exp: -5}
a_tuple = {123_456_789, -5}
b_tuple = {987_654_321, -5}

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

IO.puts("\n========= ADD (medium values, same exp) =========")

Benchee.run(
  %{
    "struct (current public API)" => fn -> FastDecimal.add(a_struct, b_struct) end,
    "tuple {coef, exp}          " => fn -> Variants.tuple_add(a_tuple, b_tuple) end,
    "raw integers               " => fn -> Variants.raw_add(123_456_789, -5, 987_654_321, -5) end
  },
  bench_opts
)

IO.puts("\n========= MULT (medium values) =========")

Benchee.run(
  %{
    "struct (current public API)" => fn -> FastDecimal.mult(a_struct, b_struct) end,
    "tuple {coef, exp}          " => fn -> Variants.tuple_mult(a_tuple, b_tuple) end,
    "raw integers               " => fn -> Variants.raw_mult(123_456_789, -5, 987_654_321, -5) end
  },
  bench_opts
)
