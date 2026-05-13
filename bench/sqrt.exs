# sqrt benchmarks: Newton-Raphson with configurable precision.
#
# Run with: `mix run bench/sqrt.exs`
#
# Decimal v2.4 doesn't ship `sqrt`, so we compare against a couple of reference
# implementations: floating-point sqrt cast back (lossy but fast) and an
# externally implemented Newton-Raphson without our isqrt initial-guess.

Decimal.Context.set(%Decimal.Context{precision: 28})

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

values = %{
  "sqrt(2)" => FastDecimal.new("2"),
  "sqrt(100)" => FastDecimal.new("100"),
  "sqrt(0.0001)" => FastDecimal.new("0.0001"),
  "sqrt(1234.5678)" => FastDecimal.new("1234.5678"),
  "sqrt(1e50)" => FastDecimal.new("1" <> String.duplicate("0", 50)),
  "sqrt(1e-50)" => FastDecimal.new("1" <> "e-50")
}

IO.puts("\n========= sqrt at default precision (28) =========")

for {label, fd} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "fastdec sqrt" => fn -> FastDecimal.sqrt(fd) end,
      "float sqrt (lossy)" => fn ->
        f = FastDecimal.to_float(fd)
        FastDecimal.new(Float.to_string(:math.sqrt(f)))
      end
    },
    bench_opts
  )
end

IO.puts("\n========= sqrt(2) at various precisions =========")

fd = FastDecimal.new("2")

for p <- [5, 10, 28, 50, 100, 200] do
  IO.puts("\n--- precision #{p} ---")

  Benchee.run(
    %{
      "fastdec sqrt p=#{p}" => fn -> FastDecimal.sqrt(fd, precision: p) end
    },
    bench_opts
  )
end

IO.puts("\n========= sqrt of special values (should be near-zero cost) =========\n")

nan = FastDecimal.nan()
inf = FastDecimal.inf()
zero = FastDecimal.new("0")

Benchee.run(
  %{
    "sqrt(NaN)" => fn -> FastDecimal.sqrt(nan) end,
    "sqrt(Inf)" => fn -> FastDecimal.sqrt(inf) end,
    "sqrt(0)  " => fn -> FastDecimal.sqrt(zero) end
  },
  bench_opts
)
