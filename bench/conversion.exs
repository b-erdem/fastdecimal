# Conversion benchmarks: to_string with all formats, to_integer, to_float,
# cast, from_float.
#
# Run with: `mix run bench/conversion.exs`

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

values = %{
  "small (1.23)" => %{
    fd: FastDecimal.new("1.23"),
    dec: Decimal.new("1.23")
  },
  "medium (1234.56789)" => %{
    fd: FastDecimal.new("1234.56789"),
    dec: Decimal.new("1234.56789")
  },
  "large (1234567890123.45678)" => %{
    fd: FastDecimal.new("1234567890123.45678"),
    dec: Decimal.new("1234567890123.45678")
  },
  "negative with sign" => %{
    fd: FastDecimal.new("-42.5"),
    dec: Decimal.new("-42.5")
  },
  "tiny fraction (0.0000001)" => %{
    fd: FastDecimal.new("0.0000001"),
    dec: Decimal.new("0.0000001")
  }
}

IO.puts("\n========= to_string/1 (:normal default) =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal" => fn -> Decimal.to_string(t.dec) end,
      "fastdec" => fn -> FastDecimal.to_string(t.fd) end
    },
    bench_opts
  )
end

IO.puts("\n========= to_string/2 :scientific =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal :scientific" => fn -> Decimal.to_string(t.dec, :scientific) end,
      "fastdec :scientific" => fn -> FastDecimal.to_string(t.fd, :scientific) end
    },
    bench_opts
  )
end

IO.puts("\n========= to_string/2 :xsd =========")

for {label, t} <- values do
  IO.puts("\n--- #{label} ---")

  Benchee.run(
    %{
      "decimal :xsd" => fn -> Decimal.to_string(t.dec, :xsd) end,
      "fastdec :xsd" => fn -> FastDecimal.to_string(t.fd, :xsd) end
    },
    bench_opts
  )
end

IO.puts("\n========= to_integer/1 (when exact) =========\n")

fd_int = FastDecimal.new(123_456)
dec_int = Decimal.new(123_456)

Benchee.run(
  %{
    "decimal to_integer" => fn -> Decimal.to_integer(dec_int) end,
    "fastdec to_integer" => fn -> FastDecimal.to_integer(fd_int) end
  },
  bench_opts
)

IO.puts("\n========= to_float/1 (lossy) =========\n")

fd = FastDecimal.new("1234.56789")
dec = Decimal.new("1234.56789")

Benchee.run(
  %{
    "decimal to_float" => fn -> Decimal.to_float(dec) end,
    "fastdec to_float" => fn -> FastDecimal.to_float(fd) end
  },
  bench_opts
)

IO.puts("\n========= cast/1 from various input types =========\n")

Benchee.run(
  %{
    "fastdec cast(string)" => fn -> FastDecimal.cast("1234.56789") end,
    "fastdec cast(integer)" => fn -> FastDecimal.cast(123_456) end,
    "fastdec cast(float)" => fn -> FastDecimal.cast(1234.56789) end,
    "fastdec cast(Decimal)" => fn -> FastDecimal.cast(Decimal.new("1234.56789")) end,
    "fastdec cast(FastDecimal)" => fn -> FastDecimal.cast(FastDecimal.new("1234.56789")) end
  },
  bench_opts
)
