# Realistic workload benchmarks.
#
# Run with: `mix run bench/realistic.exs`
#
# These simulate typical fintech / ledger code patterns: lots of small
# decimals, a mix of arithmetic, totals over lists, percentage calculations.
# They're the closest stand-in for "what users will actually do" in production.

Decimal.Context.set(%Decimal.Context{precision: 28})

bench_opts = [
  time: 2,
  warmup: 0.5,
  print: [configuration: false, fast_warning: false],
  formatters: [{Benchee.Formatters.Console, comparison: true, extended_statistics: false}]
]

# ---- Workload 1: invoice total --------------------------------------------
# 50 line items, each with a price and quantity. Compute the total.

line_items = for i <- 1..50 do
  %{
    price_dec: Decimal.new("#{rem(i * 31, 100)}.#{rem(i * 47, 100)}"),
    price_fd: FastDecimal.new("#{rem(i * 31, 100)}.#{rem(i * 47, 100)}"),
    qty_dec: Decimal.new(rem(i, 7) + 1),
    qty_fd: FastDecimal.new(rem(i, 7) + 1)
  }
end

IO.puts("\n========= Workload 1: invoice total (50 line items × price) =========\n")

Benchee.run(
  %{
    "decimal" => fn ->
      Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Decimal.mult(item.price_dec, item.qty_dec))
      end)
    end,
    "fastdec" => fn ->
      Enum.reduce(line_items, FastDecimal.new(0), fn item, acc ->
        FastDecimal.add(acc, FastDecimal.mult(item.price_fd, item.qty_fd))
      end)
    end
  },
  bench_opts
)

# ---- Workload 2: apply tax + discount -------------------------------------

tax_dec = Decimal.new("0.0825")
tax_fd = FastDecimal.new("0.0825")
discount_dec = Decimal.new("0.10")
discount_fd = FastDecimal.new("0.10")
prices_dec = for _ <- 1..100, do: Decimal.new("#{:rand.uniform(1000)}.#{:rand.uniform(100)}")
prices_fd = for p <- prices_dec, do: FastDecimal.new(Decimal.to_string(p, :normal))

IO.puts("\n========= Workload 2: apply 10% discount + 8.25% tax to 100 prices =========\n")

Benchee.run(
  %{
    "decimal" => fn ->
      Enum.map(prices_dec, fn price ->
        discounted = Decimal.sub(price, Decimal.mult(price, discount_dec))
        Decimal.add(discounted, Decimal.mult(discounted, tax_dec))
      end)
    end,
    "fastdec" => fn ->
      Enum.map(prices_fd, fn price ->
        discounted = FastDecimal.sub(price, FastDecimal.mult(price, discount_fd))
        FastDecimal.add(discounted, FastDecimal.mult(discounted, tax_fd))
      end)
    end
  },
  bench_opts
)

# ---- Workload 3: currency conversion + rounding ---------------------------

rate_dec = Decimal.new("1.0823")
rate_fd = FastDecimal.new("1.0823")

IO.puts("\n========= Workload 3: convert 100 prices via FX rate, round to 2dp =========\n")

Benchee.run(
  %{
    "decimal" => fn ->
      Enum.map(prices_dec, fn price ->
        Decimal.round(Decimal.mult(price, rate_dec), 2, :half_even)
      end)
    end,
    "fastdec" => fn ->
      Enum.map(prices_fd, fn price ->
        FastDecimal.round(FastDecimal.mult(price, rate_fd), 2, :half_even)
      end)
    end
  },
  bench_opts
)

# ---- Workload 4: aggregate stats ------------------------------------------

IO.puts("\n========= Workload 4: sum, min, max of 1000 amounts =========\n")

amounts_dec = for _ <- 1..1000, do: Decimal.new("#{:rand.uniform(10_000)}.#{:rand.uniform(100)}")
amounts_fd = for d <- amounts_dec, do: FastDecimal.new(Decimal.to_string(d, :normal))

Benchee.run(
  %{
    "decimal sum+min+max" => fn ->
      total = Enum.reduce(amounts_dec, Decimal.new(0), &Decimal.add/2)
      [first | rest] = amounts_dec
      {min, max} =
        Enum.reduce(rest, {first, first}, fn x, {mn, mx} ->
          {Decimal.min(mn, x), Decimal.max(mx, x)}
        end)
      {total, min, max}
    end,
    "fastdec sum+min+max" => fn ->
      total = FastDecimal.sum(amounts_fd)
      [first | rest] = amounts_fd
      {min, max} =
        Enum.reduce(rest, {first, first}, fn x, {mn, mx} ->
          {FastDecimal.min(mn, x), FastDecimal.max(mx, x)}
        end)
      {total, min, max}
    end
  },
  bench_opts
)

# ---- Workload 5: parse + cast a CSV row ----------------------------------

# Mimic parsing 100 numeric strings from a CSV
csv_strings = for i <- 1..100, do: "#{rem(i * 31, 1000)}.#{rem(i * 47, 100)}"

IO.puts("\n========= Workload 5: parse 100 strings (CSV ingestion) =========\n")

Benchee.run(
  %{
    "decimal new/1" => fn -> Enum.map(csv_strings, &Decimal.new/1) end,
    "fastdec new/1" => fn -> Enum.map(csv_strings, &FastDecimal.new/1) end,
    "fastdec cast/1" => fn ->
      Enum.map(csv_strings, fn s ->
        {:ok, d} = FastDecimal.cast(s)
        d
      end)
    end
  },
  bench_opts
)
