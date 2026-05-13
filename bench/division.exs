# Division benchmarks: div, div_int, div_rem, rem.
# Covers the full division surface at multiple value sizes and precisions.
#
# Run with: `mix run bench/division.exs`

alias FastDecimal.Compat

Decimal.Context.set(%Decimal.Context{precision: 28, rounding: :half_even})

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

values = %{
  "small (1.23 / 4.567)" => %{
    a_dec: Decimal.new("1.23"),
    b_dec: Decimal.new("4.567"),
    a_fd: FastDecimal.new("1.23"),
    b_fd: FastDecimal.new("4.567")
  },
  "medium (1234.56789 / 9876.54321)" => %{
    a_dec: Decimal.new("1234.56789"),
    b_dec: Decimal.new("9876.54321"),
    a_fd: FastDecimal.new("1234.56789"),
    b_fd: FastDecimal.new("9876.54321")
  },
  "large (10^14 / 10^13)" => %{
    a_dec: Decimal.new("1234567890123.45678"),
    b_dec: Decimal.new("9876543210987.65432"),
    a_fd: FastDecimal.new("1234567890123.45678"),
    b_fd: FastDecimal.new("9876543210987.65432")
  }
}

IO.puts("\n========= div/3 at precision 28 =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal" => fn -> Decimal.div(t.a_dec, t.b_dec) end,
      "fastdec" => fn -> FastDecimal.div(t.a_fd, t.b_fd) end,
      "compat " => fn -> Compat.div(t.a_fd, t.b_fd) end
    },
    bench_opts
  )
end

IO.puts("\n========= div/3 at various precisions (medium values) =========")

for p <- [5, 10, 28, 50] do
  IO.puts("\n--- precision #{p} ---")
  t = values["medium (1234.56789 / 9876.54321)"]

  Benchee.run(
    %{
      "decimal" => fn ->
        Decimal.Context.with(%Decimal.Context{precision: p, rounding: :half_even}, fn ->
          Decimal.div(t.a_dec, t.b_dec)
        end)
      end,
      "fastdec" => fn -> FastDecimal.div(t.a_fd, t.b_fd, precision: p) end
    },
    bench_opts
  )
end

IO.puts("\n========= div_int/2 =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal Decimal.div_int" => fn -> Decimal.div_int(t.a_dec, t.b_dec) end,
      "fastdec               " => fn -> FastDecimal.div_int(t.a_fd, t.b_fd) end
    },
    bench_opts
  )
end

IO.puts("\n========= div_rem/2 =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal Decimal.div_rem" => fn -> Decimal.div_rem(t.a_dec, t.b_dec) end,
      "fastdec               " => fn -> FastDecimal.div_rem(t.a_fd, t.b_fd) end
    },
    bench_opts
  )
end

IO.puts("\n========= rem/2 =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal Decimal.rem" => fn -> Decimal.rem(t.a_dec, t.b_dec) end,
      "fastdec           " => fn -> FastDecimal.rem(t.a_fd, t.b_fd) end
    },
    bench_opts
  )
end

IO.puts("\n========= Special: dividing very large by very small =========\n")
# This is a worst-case for fixed-precision libs (rust_decimal would overflow).
big_str = "1" <> String.duplicate("0", 50)
small_str = "1e-20"

Benchee.run(
  %{
    "fastdec big/small" => fn ->
      FastDecimal.div(FastDecimal.new(big_str), FastDecimal.new(small_str), precision: 28)
    end,
    "decimal big/small" => fn ->
      Decimal.div(Decimal.new(big_str), Decimal.new(small_str))
    end
  },
  bench_opts
)
