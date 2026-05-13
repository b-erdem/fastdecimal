# Batch ops benchmark: sum / product over a list.
#
# Run with: `mix run bench/batch.exs`
#
# Compares pure-Elixir batch operations vs Decimal's reduce pattern at four
# list sizes (10, 100, 1k, 10k).

list_dec = fn n ->
  for i <- 1..n, do: Decimal.new("#{i}.#{rem(i * 17, 100)}")
end

list_fd = fn n ->
  for i <- 1..n, do: FastDecimal.new("#{i}.#{rem(i * 17, 100)}")
end

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

IO.puts("\n========= SUM over N values =========")

for n <- [10, 100, 1_000, 10_000] do
  IO.puts("\n--- n = #{n} ---")
  ld = list_dec.(n)
  lf = list_fd.(n)

  Benchee.run(
    %{
      "decimal reduce" => fn -> Enum.reduce(ld, Decimal.new(0), &Decimal.add/2) end,
      "fastdec sum   " => fn -> FastDecimal.sum(lf) end
    },
    bench_opts
  )
end

IO.puts("\n========= PRODUCT over N values =========")

for n <- [10, 100, 1_000] do
  IO.puts("\n--- n = #{n} ---")
  # Use small values to avoid blowing up coefs into huge bignums for the product.
  small_dec = for _i <- 1..n, do: Decimal.new("1.01")
  small_fd = for _i <- 1..n, do: FastDecimal.new("1.01")

  Benchee.run(
    %{
      "decimal reduce" => fn -> Enum.reduce(small_dec, Decimal.new(1), &Decimal.mult/2) end,
      "fastdec product" => fn -> FastDecimal.product(small_fd) end
    },
    bench_opts
  )
end
