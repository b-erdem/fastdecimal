# Parse strategy shootout.
#
# Run with: `mix run bench/parse.exs`
#
# Two pure-Elixir strategies for parsing decimal strings:
#
#   walk  — character-by-character state machine using `<<d, rest::binary>>`
#           recursion. Each step creates a sub-binary reference (~32 bytes).
#
#   split — single `:binary.match/2` to find ".", then `:erlang.binary_to_integer/1`
#           on each part. Lower per-byte cost; relies on a native BEAM helper.
#
# The decimal library is included for context. Winner takes the public API
# slot in `FastDecimal.new/1`.

alias FastDecimal.Parser

inputs = [
  "0",
  "1.23",
  "1234.56789",
  "1234567890123.45678",
  "-100.5",
  ".5",
  "5.",
  "0.0000000001",
  String.duplicate("9", 30)
]

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

for s <- inputs do
  IO.puts("\n--- parsing #{inspect(s)} ---")

  Benchee.run(
    %{
      "split   " => fn -> Parser.parse_split(s) end,
      "walk    " => fn -> Parser.parse_walk(s) end,
      "decimal " => fn -> Decimal.new(s) end
    },
    bench_opts
  )
end
