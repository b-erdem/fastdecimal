# Head-to-head benchmark: FastDecimal vs ericmj/decimal vs Compat shim.
#
# Run with: `mix run bench/arithmetic.exs`
#
# Compares:
#   decimal  — ericmj/decimal v2.4 baseline
#   fastdec  — FastDecimal (struct-based, pure Elixir)
#   compat   — FastDecimal.Compat shim with input coercion overhead
#
# For the headline summary with statistical rigor (median + IQR + stability),
# see bench/summary.exs (`mix bench`).

import FastDecimal, only: [sigil_d: 2]

alias FastDecimal.Compat

Decimal.Context.set(%Decimal.Context{precision: 28, rounding: :half_even})

triples = %{
  "small (1.23 + 4.567)" => %{
    a_dec: Decimal.new("1.23"),
    b_dec: Decimal.new("4.567"),
    a_fd: ~d"1.23",
    b_fd: ~d"4.567",
    a_str: "1.23",
    b_str: "4.567"
  },
  "medium (1234.56789 + 9876.54321)" => %{
    a_dec: Decimal.new("1234.56789"),
    b_dec: Decimal.new("9876.54321"),
    a_fd: ~d"1234.56789",
    b_fd: ~d"9876.54321",
    a_str: "1234.56789",
    b_str: "9876.54321"
  },
  "large (1234567890123.45678 + 9876543210987.65432)" => %{
    a_dec: Decimal.new("1234567890123.45678"),
    b_dec: Decimal.new("9876543210987.65432"),
    a_fd: ~d"1234567890123.45678",
    b_fd: ~d"9876543210987.65432",
    a_str: "1234567890123.45678",
    b_str: "9876543210987.65432"
  }
}

defmodule Bench do
  def sum_dec(list), do: Enum.reduce(list, Decimal.new(0), &Decimal.add/2)
  def sum_fd(list), do: Enum.reduce(list, FastDecimal.new(0), &FastDecimal.add/2)
end

list_dec = for n <- 1..100, do: Decimal.new("#{n}.#{rem(n * 17, 100)}")
list_fd = for n <- 1..100, do: FastDecimal.new("#{n}.#{rem(n * 17, 100)}")

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

run_bench = fn name, scenarios ->
  IO.puts("\n========= #{name} =========")

  for {label, t} <- triples do
    IO.puts("\n--- #{label} ---")
    Benchee.run(scenarios.(t), bench_opts)
  end
end

run_bench.("ADD", fn t ->
  %{
    "decimal" => fn -> Decimal.add(t.a_dec, t.b_dec) end,
    "fastdec" => fn -> FastDecimal.add(t.a_fd, t.b_fd) end,
    "compat " => fn -> Compat.add(t.a_fd, t.b_fd) end
  }
end)

run_bench.("SUB", fn t ->
  %{
    "decimal" => fn -> Decimal.sub(t.a_dec, t.b_dec) end,
    "fastdec" => fn -> FastDecimal.sub(t.a_fd, t.b_fd) end,
    "compat " => fn -> Compat.sub(t.a_fd, t.b_fd) end
  }
end)

run_bench.("MULT", fn t ->
  %{
    "decimal" => fn -> Decimal.mult(t.a_dec, t.b_dec) end,
    "fastdec" => fn -> FastDecimal.mult(t.a_fd, t.b_fd) end,
    "compat " => fn -> Compat.mult(t.a_fd, t.b_fd) end
  }
end)

run_bench.("DIV (precision 28)", fn t ->
  %{
    "decimal" => fn -> Decimal.div(t.a_dec, t.b_dec) end,
    "fastdec" => fn -> FastDecimal.div(t.a_fd, t.b_fd) end,
    "compat " => fn -> Compat.div(t.a_fd, t.b_fd) end
  }
end)

run_bench.("COMPARE", fn t ->
  %{
    "decimal" => fn -> Decimal.compare(t.a_dec, t.b_dec) end,
    "fastdec" => fn -> FastDecimal.compare(t.a_fd, t.b_fd) end,
    "compat " => fn -> Compat.compare(t.a_fd, t.b_fd) end
  }
end)

run_bench.("NEGATE", fn t ->
  %{
    "decimal" => fn -> Decimal.negate(t.a_dec) end,
    "fastdec" => fn -> FastDecimal.negate(t.a_fd) end,
    "compat " => fn -> Compat.negate(t.a_fd) end
  }
end)

IO.puts("\n========= PARSE =========")

for s <- ["1.23", "1234.56789", "1234567890123.45678"] do
  IO.puts("\n--- parsing \"#{s}\" ---")

  Benchee.run(
    %{
      "decimal" => fn -> Decimal.new(s) end,
      "fastdec" => fn -> FastDecimal.new(s) end,
      "compat " => fn -> Compat.new(s) end
    },
    bench_opts
  )
end

IO.puts("\n========= TO_STRING =========")

for {label, t} <- triples do
  IO.puts("\n--- #{label} (first operand) ---")

  Benchee.run(
    %{
      "decimal" => fn -> Decimal.to_string(t.a_dec) end,
      "fastdec" => fn -> FastDecimal.to_string(t.a_fd) end,
      "compat " => fn -> Compat.to_string(t.a_fd) end
    },
    bench_opts
  )
end

IO.puts("\n========= BATCH: SUM OF 100 DECIMALS =========")

Benchee.run(
  %{
    "decimal reduce" => fn -> Bench.sum_dec(list_dec) end,
    "fastdec sum   " => fn -> FastDecimal.sum(list_fd) end
  },
  bench_opts
)

IO.puts("\n========= SIGIL vs RUNTIME PARSE (literal construction) =========")

Benchee.run(
  %{
    "fastdec ~d sigil (compile-time)" => fn -> ~d"123.456" end,
    "fastdec new/1 (runtime parse)" => fn -> FastDecimal.new("123.456") end,
    "decimal new/1" => fn -> Decimal.new("123.456") end
  },
  bench_opts
)
