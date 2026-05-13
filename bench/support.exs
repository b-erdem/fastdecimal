defmodule Bench.Support do
  @moduledoc """
  Shared measurement helpers used by `bench/summary.exs` and other bench
  scripts that want statistically reliable numbers.

  ## Methodology

  For each scenario we take **N independent samples** (default 7). Each sample:

    1. Runs in a fresh spawned process to reset BEAM state between samples
    2. Warms up with 1,000 calls so the JIT specializes the call site
    3. Triggers GC to start from a clean heap
    4. Measures `iterations` (default 200,000) calls in a tight loop
    5. Reports `ns/iteration` using `:erlang.monotonic_time(:nanosecond)`,
       which has true nanosecond resolution on macOS/Linux (`:timer.tc` is
       microsecond)

  Per scenario we then report **median, IQR (25th–75th percentile), and
  min/max** across the N samples. The IQR is the trustworthy headline number
  — it survives outliers from GC pauses, scheduler steals, and core swaps.

  ## Why not just benchee?

  Benchee runs each scenario *once* and computes statistics from its internal
  iteration loop. That's fine for "is this op fast?" but it doesn't catch
  cross-run instability (e.g., one run lands on an E-core, another on a
  P-core). N independent samples in fresh processes does.

  ## Noise sources we can't eliminate

    * macOS scheduler bouncing across performance / efficiency cores
    * BEAM GC pauses inside the measurement window
    * Background processes competing for cores

  We report the range so the reader can see noise impact directly.
  """

  @default_samples 7
  @default_iterations 200_000
  @warmup_iterations 1_000

  @type samples :: %{
          median: float(),
          p25: float(),
          p75: float(),
          min: float(),
          max: float(),
          values: [float()],
          n: pos_integer()
        }

  @doc """
  Run `fun` `samples` times, each time over `iterations` calls in a tight
  loop. Returns an aggregated stats map.
  """
  @spec measure(label :: term(), (-> any()), keyword()) :: samples()
  def measure(_label, fun, opts \\ []) do
    n_samples = Keyword.get(opts, :samples, @default_samples)
    iterations = Keyword.get(opts, :iterations, @default_iterations)

    values =
      Enum.map(1..n_samples, fn _ -> one_sample(fun, iterations) end)

    aggregate(values)
  end

  defp one_sample(fun, iterations) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        # Set process priority high — biases toward performance cores on macOS
        # when running this benchmark in a non-loaded system.
        Process.flag(:priority, :high)

        # Warmup gives the JIT time to specialize this call site.
        loop(fun, @warmup_iterations)

        :erlang.garbage_collect()

        t1 = :erlang.monotonic_time(:nanosecond)
        loop(fun, iterations)
        t2 = :erlang.monotonic_time(:nanosecond)

        send(parent, {:result, ref, (t2 - t1) / iterations})
      end)

    receive do
      {:result, ^ref, ns} -> ns
    after
      60_000 ->
        Process.exit(pid, :kill)
        raise "measurement timeout"
    end
  end

  # Unrolled-ish tight loop. Tail-call optimized; the function call cost is
  # part of every BEAM benchmark and can't be eliminated without inlining.
  defp loop(_, 0), do: :ok

  defp loop(fun, n) do
    fun.()
    loop(fun, n - 1)
  end

  @spec aggregate([float()]) :: samples()
  def aggregate(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      median: percentile(sorted, n, 0.50),
      p25: percentile(sorted, n, 0.25),
      p75: percentile(sorted, n, 0.75),
      min: List.first(sorted),
      max: List.last(sorted),
      values: values,
      n: n
    }
  end

  defp percentile(sorted, n, p) do
    idx = Kernel.min(n - 1, trunc(p * n))
    Enum.at(sorted, idx)
  end

  @doc """
  Compute speedup as `median(a) / median(b)`. Also returns a range derived
  from the conservative IQR-edge ratios — the "speedup might be as low as X
  and as high as Y across the IQR" interpretation.
  """
  def speedup(slower, faster) do
    point = slower.median / faster.median
    low = slower.p25 / faster.p75
    high = slower.p75 / faster.p25
    %{median: point, low: low, high: high}
  end

  @doc """
  Did the speedup result come out stable across all samples? Returns true
  when the IQR-edge ratios both clear `min_x` (i.e., even the pessimistic
  bound shows the claimed speedup).
  """
  def stable?(speedup, min_x \\ 1.0), do: speedup.low >= min_x

  @doc """
  Auto-detect runtime info to print at the top of each bench output.
  """
  def runtime_info do
    # `emu_flavor` is the right field — `emu_type` is :opt for both JIT and
    # non-JIT builds. (Got bit by that initially — these benches were
    # claimed to be "no JIT" when they were always on JIT.)
    emu_flavor = :erlang.system_info(:emu_flavor)

    %{
      date: Date.utc_today(),
      otp: System.otp_release(),
      elixir: System.version(),
      os: :os.type(),
      cpu_count: :erlang.system_info(:logical_processors),
      schedulers: :erlang.system_info(:schedulers_online),
      emu_flavor: emu_flavor,
      jit?: emu_flavor == :jit,
      emu_label:
        case emu_flavor do
          :jit -> "BEAMAsm JIT enabled"
          :emu -> "threaded-code interpreter (no JIT)"
          other -> to_string(other)
        end
    }
  end

  def print_runtime_header do
    info = runtime_info()
    {os_family, os_name} = info.os

    IO.puts("""

    Runtime:
      Date              : #{info.date}
      Erlang/OTP        : #{info.otp} (#{info.emu_label})
      Elixir            : #{info.elixir}
      OS                : #{os_family}/#{os_name}
      Logical CPUs      : #{info.cpu_count}
      BEAM schedulers   : #{info.schedulers}
    """)
  end

  @doc """
  Format a `samples()` map as "median ns (p25–p75)" for table display.
  """
  def fmt_samples(%{median: m, p25: p25, p75: p75}) do
    cond do
      m < 1_000 ->
        :io_lib.format("~6.1f ns (~.1f-~.1f)", [m, p25, p75]) |> :erlang.iolist_to_binary()

      m < 1_000_000 ->
        :io_lib.format("~6.2f us (~.2f-~.2f)", [m / 1_000, p25 / 1_000, p75 / 1_000])
        |> :erlang.iolist_to_binary()

      true ->
        :io_lib.format("~6.2f ms (~.2f-~.2f)", [
          m / 1_000_000,
          p25 / 1_000_000,
          p75 / 1_000_000
        ])
        |> :erlang.iolist_to_binary()
    end
  end
end
