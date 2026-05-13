# Rounding benchmarks: round/3 with all 7 modes × input sizes.
#
# Run with: `mix run bench/rounding.exs`

Decimal.Context.set(%Decimal.Context{precision: 28})

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

values = %{
  "small (1.235 → 2 places)" => %{
    fd: FastDecimal.new("1.235"),
    dec: Decimal.new("1.235"),
    places: 2
  },
  "medium (1234.56789 → 3 places)" => %{
    fd: FastDecimal.new("1234.56789"),
    dec: Decimal.new("1234.56789"),
    places: 3
  },
  "negative (-1234.56789 → 3 places)" => %{
    fd: FastDecimal.new("-1234.56789"),
    dec: Decimal.new("-1234.56789"),
    places: 3
  },
  "many digits (123456789.987654321 → 5)" => %{
    fd: FastDecimal.new("123456789.987654321"),
    dec: Decimal.new("123456789.987654321"),
    places: 5
  },
  "negative places (-1 for tens)" => %{
    fd: FastDecimal.new("123.456"),
    dec: Decimal.new("123.456"),
    places: -1
  }
}

IO.puts("\n========= round/3 with :half_even (default for FastDecimal) =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal" => fn -> Decimal.round(t.dec, t.places, :half_even) end,
      "fastdec" => fn -> FastDecimal.round(t.fd, t.places, :half_even) end
    },
    bench_opts
  )
end

IO.puts("\n========= round/3: all 7 modes head-to-head =========\n")

fd = FastDecimal.new("1234.56789")
dec = Decimal.new("1234.56789")
places = 3

for mode <- [:half_even, :half_up, :half_down, :down, :up, :floor, :ceiling] do
  IO.puts("\n--- mode #{inspect(mode)} ---")

  Benchee.run(
    %{
      "decimal" => fn -> Decimal.round(dec, places, mode) end,
      "fastdec" => fn -> FastDecimal.round(fd, places, mode) end
    },
    bench_opts
  )
end

IO.puts("\n========= round/3: no-op case (input already at target precision) =========\n")

fd = FastDecimal.new("1.23")
dec = Decimal.new("1.23")

Benchee.run(
  %{
    "decimal round to 5 places (no-op)" => fn -> Decimal.round(dec, 5) end,
    "fastdec round to 5 places (no-op)" => fn -> FastDecimal.round(fd, 5) end
  },
  bench_opts
)
