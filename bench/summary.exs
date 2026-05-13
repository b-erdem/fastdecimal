# Headline benchmark with rigorous methodology.
#
# Run with: `mix bench` (alias for `mix run bench/summary.exs`).
#
# Methodology: see bench/support.exs. tl;dr — 7 samples per scenario, each in
# a fresh process with 200k iterations. We report median, IQR (25th-75th
# percentile), and a "stable?" flag that's true only when even the pessimistic
# (p75/p25) speedup beats 2×.

Code.require_file("support.exs", __DIR__)

alias Bench.Support

# ---- Runtime info ---------------------------------------------------------

Support.print_runtime_header()

# Make sure Decimal's context is a known value (matches our `div` default).
Decimal.Context.set(%Decimal.Context{precision: 28, rounding: :half_even})

# ---- Test values ----------------------------------------------------------

a_dec_m = Decimal.new("1234.56789")
b_dec_m = Decimal.new("9876.54321")
a_dec_l = Decimal.new("1234567890123.45678")
b_dec_l = Decimal.new("9876543210987.65432")

a_fd_m = FastDecimal.new("1234.56789")
b_fd_m = FastDecimal.new("9876.54321")
a_fd_l = FastDecimal.new("1234567890123.45678")
b_fd_l = FastDecimal.new("9876543210987.65432")

list_dec = for n <- 1..100, do: Decimal.new("#{n}.#{rem(n * 17, 100)}")
list_fd = for n <- 1..100, do: FastDecimal.new("#{n}.#{rem(n * 17, 100)}")

scenarios = [
  {"add", "medium", fn -> Decimal.add(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.add(a_fd_m, b_fd_m) end},
  {"add", "large", fn -> Decimal.add(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.add(a_fd_l, b_fd_l) end},
  {"sub", "medium", fn -> Decimal.sub(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.sub(a_fd_m, b_fd_m) end},
  {"sub", "large", fn -> Decimal.sub(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.sub(a_fd_l, b_fd_l) end},
  {"mult", "medium", fn -> Decimal.mult(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.mult(a_fd_m, b_fd_m) end},
  {"mult", "large", fn -> Decimal.mult(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.mult(a_fd_l, b_fd_l) end},
  {"div p=28", "medium", fn -> Decimal.div(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.div(a_fd_m, b_fd_m) end},
  {"div p=28", "large", fn -> Decimal.div(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.div(a_fd_l, b_fd_l) end},
  {"div_int", "medium", fn -> Decimal.div_int(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.div_int(a_fd_m, b_fd_m) end},
  {"div_rem", "medium", fn -> Decimal.div_rem(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.div_rem(a_fd_m, b_fd_m) end},
  {"compare", "medium", fn -> Decimal.compare(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.compare(a_fd_m, b_fd_m) end},
  {"compare", "large", fn -> Decimal.compare(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.compare(a_fd_l, b_fd_l) end},
  {"negate", "medium", fn -> Decimal.negate(a_dec_m) end,
   fn -> FastDecimal.negate(a_fd_m) end},
  {"abs", "medium", fn -> Decimal.abs(a_dec_m) end, fn -> FastDecimal.abs(a_fd_m) end},
  {"round (3dp)", "medium", fn -> Decimal.round(a_dec_m, 3) end,
   fn -> FastDecimal.round(a_fd_m, 3) end},
  {"normalize", "medium", fn -> Decimal.normalize(a_dec_m) end,
   fn -> FastDecimal.normalize(a_fd_m) end},
  {"parse", "small", fn -> Decimal.new("1.23") end, fn -> FastDecimal.new("1.23") end},
  {"parse", "medium", fn -> Decimal.new("1234.56789") end,
   fn -> FastDecimal.new("1234.56789") end},
  {"to_string", "medium", fn -> Decimal.to_string(a_dec_m) end,
   fn -> FastDecimal.to_string(a_fd_m) end},
  {"to_string sci", "medium", fn -> Decimal.to_string(a_dec_m, :scientific) end,
   fn -> FastDecimal.to_string(a_fd_m, :scientific) end},
  {"to_integer", "medium", fn -> Decimal.to_integer(Decimal.new(123_456)) end,
   fn -> FastDecimal.to_integer(FastDecimal.new(123_456)) end},
  {"sum of 100", "—", fn -> Enum.reduce(list_dec, Decimal.new(0), &Decimal.add/2) end,
   fn -> FastDecimal.sum(list_fd) end}
]

IO.puts(
  "Sampling: #{7} independent samples × 200,000 iterations per scenario per implementation.\n"
)

# ---- Run ------------------------------------------------------------------

header =
  [
    String.pad_trailing("op", 16),
    " | ",
    String.pad_trailing("size", 8),
    " | ",
    String.pad_trailing("decimal (median, IQR)", 28),
    " | ",
    String.pad_trailing("fastdec (median, IQR)", 28),
    " | ",
    String.pad_trailing("speedup", 14),
    " | stable?"
  ]
  |> Enum.join()

IO.puts(header)
IO.puts(String.duplicate("-", String.length(header)))

results =
  for {op, size, dec_fn, fd_fn} <- scenarios do
    dec_samples = Support.measure({:dec, op, size}, dec_fn)
    fd_samples = Support.measure({:fd, op, size}, fd_fn)
    speedup = Support.speedup(dec_samples, fd_samples)
    stable = Support.stable?(speedup, 2.0)

    IO.puts(
      [
        String.pad_trailing(op, 16),
        " | ",
        String.pad_trailing(size, 8),
        " | ",
        String.pad_trailing(Support.fmt_samples(dec_samples), 28),
        " | ",
        String.pad_trailing(Support.fmt_samples(fd_samples), 28),
        " | ",
        :io_lib.format("~5.2fx (~5.2f-~5.2f)", [speedup.median, speedup.low, speedup.high])
        |> :erlang.iolist_to_binary()
        |> String.pad_trailing(14),
        " | ",
        if(stable, do: "✓ ≥2x even at p25/p75", else: "△ marginal")
      ]
      |> :erlang.iolist_to_binary()
    )

    {op, size, dec_samples, fd_samples, speedup, stable}
  end

# ---- Aggregate summary ----------------------------------------------------

speedup_medians = for {_, _, _, _, sp, _} <- results, do: sp.median
geomean = :math.exp(Enum.sum(Enum.map(speedup_medians, &:math.log/1)) / length(speedup_medians))

stable_count = Enum.count(results, fn {_, _, _, _, _, stable?} -> stable? end)
total = length(results)

faster_count =
  Enum.count(results, fn {_, _, _, _, sp, _} -> sp.median > 1.0 end)

slower_count = total - faster_count

IO.puts("")
IO.puts(String.duplicate("=", String.length(header)))
IO.puts("Summary across #{total} scenarios:")

IO.puts(
  "  Geometric mean speedup       : #{:io_lib.format("~5.2fx", [geomean]) |> IO.iodata_to_binary()}"
)

IO.puts(
  "  FastDecimal faster on        : #{faster_count}/#{total} scenarios" <>
    if slower_count > 0, do: "  (#{slower_count} regression — see table)", else: ""
)

IO.puts(
  "  Stable ≥2× at IQR edges      : #{stable_count}/#{total} scenarios"
)

IO.puts("")
IO.puts("Read the speedup column as: median (pessimistic-optimistic IQR-edge ratios).")
IO.puts("A stable ✓ row means even when FastDecimal's slowest p75 sample is compared")
IO.puts("to Decimal's fastest p25, FastDecimal still wins by ≥2×.")
IO.puts(String.duplicate("=", String.length(header)))
IO.puts("")
