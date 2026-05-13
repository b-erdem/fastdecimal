# Special-value benchmarks: how much overhead do NaN/Inf operations have
# compared to finite arithmetic?
#
# The hot path uses `is_integer(coef)` guards to keep finite arithmetic at the
# floor. Special values fall through to dedicated handlers. We want to confirm:
#   1. Adding the guards doesn't slow down finite arithmetic noticeably.
#   2. Special-value ops are fast enough (they don't do anything anyway — just
#      return a constant).
#
# Run with: `mix run bench/special_values.exs`

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

finite_a = FastDecimal.new("1.23")
finite_b = FastDecimal.new("4.567")

nan = FastDecimal.nan()
inf = FastDecimal.inf()
neg_inf = FastDecimal.neg_inf()

IO.puts("\n========= add: finite vs special =========\n")

Benchee.run(
  %{
    "finite + finite" => fn -> FastDecimal.add(finite_a, finite_b) end,
    "inf + finite   " => fn -> FastDecimal.add(inf, finite_b) end,
    "finite + inf   " => fn -> FastDecimal.add(finite_a, inf) end,
    "inf + inf      " => fn -> FastDecimal.add(inf, inf) end,
    "inf + neg_inf  " => fn -> FastDecimal.add(inf, neg_inf) end,
    "nan + finite   " => fn -> FastDecimal.add(nan, finite_b) end
  },
  bench_opts
)

IO.puts("\n========= mult: finite vs special =========\n")

Benchee.run(
  %{
    "finite * finite" => fn -> FastDecimal.mult(finite_a, finite_b) end,
    "inf * finite   " => fn -> FastDecimal.mult(inf, finite_b) end,
    "inf * 0        " => fn -> FastDecimal.mult(inf, FastDecimal.new(0)) end,
    "nan * finite   " => fn -> FastDecimal.mult(nan, finite_b) end
  },
  bench_opts
)

IO.puts("\n========= predicates: nan?/inf?/finite? =========\n")

Benchee.run(
  %{
    "nan?(finite)" => fn -> FastDecimal.nan?(finite_a) end,
    "nan?(nan)   " => fn -> FastDecimal.nan?(nan) end,
    "inf?(finite)" => fn -> FastDecimal.inf?(finite_a) end,
    "inf?(inf)   " => fn -> FastDecimal.inf?(inf) end,
    "finite?(finite)" => fn -> FastDecimal.finite?(finite_a) end,
    "finite?(nan)" => fn -> FastDecimal.finite?(nan) end
  },
  bench_opts
)

IO.puts("\n========= compare: finite vs special =========\n")

Benchee.run(
  %{
    "compare(finite, finite)" => fn -> FastDecimal.compare(finite_a, finite_b) end,
    "compare(inf, finite)   " => fn -> FastDecimal.compare(inf, finite_b) end,
    "compare(nan, finite)   " => fn -> FastDecimal.compare(nan, finite_b) end
  },
  bench_opts
)

IO.puts("\n========= No-op cost: is_integer guard overhead =========\n")
# This is the worst case for our guard approach: 99% of inputs hit the fast
# path, but the guard check has to happen anyway. Measure the floor.

Benchee.run(
  %{
    "FastDecimal.add (same exp finite)" => fn ->
      FastDecimal.add(finite_a, FastDecimal.new("4.56"))
    end
  },
  bench_opts
)
