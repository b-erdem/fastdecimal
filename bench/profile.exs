# Per-op profiling: time, allocations, reductions, GC pressure.
#
# Run with: `mix run bench/profile.exs`
#
# Output for each operation:
#   - Median ns/op (from benchee — wall time)
#   - Bytes allocated per op (from heap delta + GC accounting)
#   - Reductions per op (BEAM's virtual instruction counter — proxy for "work")
#   - GC cycles triggered in a tight loop
#
# Compared head-to-head: ericmj/decimal vs FastDecimal. Goal is to see where
# FastDecimal's wins/losses come from at the BEAM level — not just "faster" but
# "faster because it allocates less" or "faster because fewer reductions".

import FastDecimal, only: [sigil_d: 2]

defmodule Profile do
  @loops 100_000

  @doc """
  Run `fun` in a fresh process `@loops` times, measure:
    - wall time
    - words allocated on heap
    - reductions consumed
    - GC cycles
  """
  def measure(name, fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        # Warm up so we're not measuring first-call compilation.
        Enum.each(1..100, fn _ -> fun.() end)

        :erlang.garbage_collect()

        {:total_heap_size, heap_before} = :erlang.process_info(self(), :total_heap_size)
        minor_before = minor_gcs(self())
        {:reductions, reds_before} = :erlang.process_info(self(), :reductions)

        {time_us, _} =
          :timer.tc(fn ->
            loop(fun, @loops)
          end)

        {:reductions, reds_after} = :erlang.process_info(self(), :reductions)
        {:total_heap_size, heap_after} = :erlang.process_info(self(), :total_heap_size)
        minor_after = minor_gcs(self())

        gcs = minor_after - minor_before

        # Heap accounting: if GCs happened the heap can be smaller than baseline.
        # Approximate total bytes allocated as: words live on heap now * 8 bytes
        # + (GC count * heap size before each GC), but that's hard to recover.
        # Cheaper approximation: words on heap delta + gcs * heap_before.
        heap_delta = heap_after - heap_before
        approx_words_allocated = heap_delta + gcs * heap_before
        bytes_per_op = approx_words_allocated * 8 / @loops

        reductions_per_op = (reds_after - reds_before) / @loops
        ns_per_op = time_us * 1_000 / @loops

        send(
          parent,
          {:result, ref,
           %{
             ns_per_op: ns_per_op,
             bytes_per_op: bytes_per_op,
             reductions_per_op: reductions_per_op,
             gcs: gcs
           }}
        )
      end)

    receive do
      {:result, ^ref, result} ->
        result
    after
      30_000 ->
        Process.exit(pid, :kill)
        raise "Profile timeout for #{inspect(name)}"
    end
  end

  defp minor_gcs(pid) do
    {:garbage_collection, kvs} = :erlang.process_info(pid, :garbage_collection)
    Keyword.fetch!(kvs, :minor_gcs)
  end

  defp loop(_fun, 0), do: :ok

  defp loop(fun, n) do
    fun.()
    loop(fun, n - 1)
  end

  def print_row({name, results}) do
    decimal = results[:decimal]
    fastdec = results[:fastdec]

    speedup =
      if fastdec.ns_per_op > 0,
        do: Float.round(decimal.ns_per_op / fastdec.ns_per_op, 2),
        else: 0.0

    alloc_ratio =
      if fastdec.bytes_per_op > 0,
        do: Float.round(decimal.bytes_per_op / fastdec.bytes_per_op, 2),
        else: 0.0

    IO.puts(
      [
        String.pad_trailing(name, 26),
        " | ",
        :io_lib.format("~7.1f ns", [decimal.ns_per_op]),
        " | ",
        :io_lib.format("~7.1f ns", [fastdec.ns_per_op]),
        " | ",
        :io_lib.format("~5.2fx", [speedup]),
        " | ",
        :io_lib.format("~6.1f B", [decimal.bytes_per_op]),
        " | ",
        :io_lib.format("~6.1f B", [fastdec.bytes_per_op]),
        " | ",
        :io_lib.format("~5.2fx", [alloc_ratio]),
        " | ",
        :io_lib.format("~7.1f red", [decimal.reductions_per_op]),
        " | ",
        :io_lib.format("~7.1f red", [fastdec.reductions_per_op])
      ]
      |> :erlang.iolist_to_binary()
    )
  end
end

# ---- Setup test values ----

a_dec_s = Decimal.new("1.23")
b_dec_s = Decimal.new("4.567")
a_dec_m = Decimal.new("1234.56789")
b_dec_m = Decimal.new("9876.54321")
a_dec_l = Decimal.new("1234567890123.45678")
b_dec_l = Decimal.new("9876543210987.65432")

a_fd_s = ~d"1.23"
b_fd_s = ~d"4.567"
a_fd_m = ~d"1234.56789"
b_fd_m = ~d"9876.54321"
a_fd_l = ~d"1234567890123.45678"
b_fd_l = ~d"9876543210987.65432"

list_dec = for n <- 1..100, do: Decimal.new("#{n}.#{rem(n * 17, 100)}")
list_fd = for n <- 1..100, do: FastDecimal.new("#{n}.#{rem(n * 17, 100)}")

scenarios = [
  # {label, decimal_fn, fastdec_fn}
  {"add (small)", fn -> Decimal.add(a_dec_s, b_dec_s) end,
   fn -> FastDecimal.add(a_fd_s, b_fd_s) end},
  {"add (medium)", fn -> Decimal.add(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.add(a_fd_m, b_fd_m) end},
  {"add (large)", fn -> Decimal.add(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.add(a_fd_l, b_fd_l) end},
  {"sub (medium)", fn -> Decimal.sub(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.sub(a_fd_m, b_fd_m) end},
  {"mult (medium)", fn -> Decimal.mult(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.mult(a_fd_m, b_fd_m) end},
  {"mult (large)", fn -> Decimal.mult(a_dec_l, b_dec_l) end,
   fn -> FastDecimal.mult(a_fd_l, b_fd_l) end},
  {"div p=28 (medium)", fn -> Decimal.div(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.div(a_fd_m, b_fd_m) end},
  {"compare (medium)", fn -> Decimal.compare(a_dec_m, b_dec_m) end,
   fn -> FastDecimal.compare(a_fd_m, b_fd_m) end},
  {"negate (medium)", fn -> Decimal.negate(a_dec_m) end, fn -> FastDecimal.negate(a_fd_m) end},
  {"parse \"1.23\"", fn -> Decimal.new("1.23") end, fn -> FastDecimal.new("1.23") end},
  {"parse \"1234.56789\"", fn -> Decimal.new("1234.56789") end,
   fn -> FastDecimal.new("1234.56789") end},
  {"to_string (medium)", fn -> Decimal.to_string(a_dec_m) end,
   fn -> FastDecimal.to_string(a_fd_m) end},
  {"sum of 100",
   fn -> Enum.reduce(list_dec, Decimal.new(0), &Decimal.add/2) end,
   fn -> Enum.reduce(list_fd, FastDecimal.new(0), &FastDecimal.add/2) end}
]

# ---- Run profile ----

IO.puts("\nProfiling each operation with #{Profile |> Module.split() |> hd()}.measure/2")
IO.puts("Loops per measurement: 100,000\n")

results =
  for {label, decimal_fn, fastdec_fn} <- scenarios do
    {label,
     %{
       decimal: Profile.measure({:decimal, label}, decimal_fn),
       fastdec: Profile.measure({:fastdec, label}, fastdec_fn)
     }}
  end

# ---- Print table ----

header =
  [
    String.pad_trailing("op", 26),
    " | ",
    String.pad_trailing("dec time", 10),
    " | ",
    String.pad_trailing("fd time", 10),
    " | ",
    String.pad_trailing("speed", 6),
    " | ",
    String.pad_trailing("dec alc", 6),
    " | ",
    String.pad_trailing("fd alc", 6),
    " | ",
    String.pad_trailing("alc/x", 6),
    " | ",
    String.pad_trailing("dec red", 9),
    " | ",
    String.pad_trailing("fd red", 9)
  ]
  |> Enum.join()

IO.puts(header)
IO.puts(String.duplicate("-", String.length(header)))

Enum.each(results, &Profile.print_row/1)

IO.puts("""

Legend:
  speed   — FastDecimal speedup (decimal time / fastdec time)
  alc/x   — FastDecimal allocation ratio (decimal bytes / fastdec bytes)
  red     — reductions per op (BEAM virtual instruction counter; lower = less work)

Notes:
  * Bytes allocated is approximated from heap delta + (gc count * heap before).
    Treat as a relative signal, not absolute.
  * Median wall-time uses :timer.tc over a tight Enum-free loop, which differs
    slightly from benchee's median. Use bench/arithmetic.exs for headline times.
  * Allocations are the most actionable signal for optimization: every per-op
    allocation costs ~10-30 ns plus GC pressure.
""")
