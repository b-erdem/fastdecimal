# FastDecimal benchmarks

Every benchmark in this directory is reproducible. Each script is self-contained — just `mix run bench/<name>.exs`.

The single-command experience: **`mix bench`** runs `summary.exs`, which produces one consolidated table covering 22 scenarios. **`mix bench.all`** runs the entire suite end-to-end.

## Files

| File | What it measures | When to run |
|---|---|---|
| `summary.exs` | **Headline table:** every op × {medium, large}, geometric-mean speedup. The bench you'd cite. | Quick "is FastDecimal still ahead?" check after a change |
| `arithmetic.exs` | Per-op times vs `decimal` and Compat shim at 3 value sizes (full benchee output) | Detailed view of add/sub/mult/div/etc with deviation |
| `division.exs` | div / div_int / div_rem / rem × sizes × precisions (5, 10, 28, 50) | Verifying division performance, picking a precision |
| `rounding.exs` | `round/3` with all 7 modes × 5 input shapes | Comparing rounding-mode overhead |
| `sqrt.exs` | `sqrt/2` at precisions 5 / 10 / 28 / 50 / 100 / 200 | Tuning sqrt-precision for your use case |
| `conversion.exs` | `to_string` (all formats) + `to_integer` + `to_float` + `cast` from various input types | Format-conversion path tuning |
| `special_values.exs` | NaN/Inf op overhead vs finite arithmetic; predicate cost | Confirming the `is_integer` guard isn't hurting the fast path |
| `batch.exs` | `sum/1` / `product/1` over 10/100/1k/10k elements: pure Elixir vs `decimal` reduce | Verifying batch wins |
| `realistic.exs` | 5 fintech-style workloads: invoice total, tax+discount, FX conversion, aggregate stats, CSV ingestion | The "would this actually help my app?" answer |
| `parse.exs` | Two parse strategies (char-walk vs split+`binary_to_integer`) across 9 inputs | Chose the public `parse/1` impl |
| `representation.exs` | `%FastDecimal{}` struct vs raw `{coef, exp}` tuple vs raw integers | Quantifying the struct wrapper cost |
| `profile.exs` | Time + bytes allocated + reductions per op (richer than benchee alone) | Investigating *why* an op is fast or slow |
| `disasm.exs` | Dumps BEAM bytecode for hot-path functions; counts `put_map_assoc` vs `put_map_exact` module-wide | Inspecting what BEAMAsm actually JITs from |

Run individual ones with `mix run bench/<name>.exs`. Pipe to `tee` if you want a record.

## Methodology

The headline `mix bench` (= `bench/summary.exs`) uses a custom harness in [`bench/support.exs`](support.exs):

- **7 independent samples per scenario per implementation**. Each sample runs in a *fresh process* (resetting BEAM state — register cache, ETS access patterns, scheduler binding) and includes 1,000 warmup iterations to let the JIT specialize the call site before measurement starts.
- **200,000 iterations per sample**, timed with `:erlang.monotonic_time(:nanosecond)` (true nanosecond resolution; `:timer.tc` is microsecond).
- A forced `:erlang.garbage_collect()` before each sample to start from a clean heap.
- Process priority set `:high` to bias the macOS scheduler toward performance cores when the system isn't loaded.
- We report **median (p25–p75 IQR)** per scenario. The IQR is the trustworthy headline number — it survives outliers from GC pauses, scheduler steals, and core swaps.
- A row is marked **stable** when even FastDecimal's p75 vs Decimal's p25 (the pessimistic IQR-edge ratio) clears 2×.

### What we report vs what we don't

- **Speedup column shows three numbers**: `median (pessimistic_ratio – optimistic_ratio)`. The middle number is what you'd see most days; the outer numbers bound what you might see on a noisy/quiet run.
- **No mean reported.** Means on sub-µs ops are dominated by 99th-percentile outliers from GC; medians are robust.
- **`profile.exs` shows allocation estimates** approximated from `heap_size_delta + (gc_count × heap_size_before_gc)`. **This is a heuristic, not a precise measurement.** Use it as a relative signal between implementations, not an absolute byte count. The "fastdec uses less garbage" claim holds across implementations but the exact byte numbers should be taken with a grain of salt.

### Reproducibility check

Across multiple consecutive runs on macOS arm64 / OTP 26 / BEAMAsm JIT, the geometric-mean speedup has landed in the range **9.67× – 10.01×**. Each scenario's specific median value drifts 5–10% per run because of macOS scheduler noise and GC interactions; the *ratios* are stable. The headline number is best read as "approximately 10×, varies by ±3% across runs."

### JIT vs non-JIT comparison

Same hardware, same Elixir, only the Erlang differs (asdf 26.0.2 with `emu_flavor=jit` vs 26.2.4 with `emu_flavor=emu`):

| Emulator | Geomean | Faster scenarios | Stable ≥2× |
|---|---:|---:|---:|
| BEAMAsm JIT (26.0.2) | **9.87×** | 21/22 | 19/22 |
| Threaded-code interpreter (26.2.4) | **7.71×** | 21/22 | 18/22 |

JIT helps FastDecimal proportionally more than `decimal` (tighter hot paths = more inlining benefit), so the speedup ratio is bigger on JIT. But the lib still wins by ~8× on non-JIT BEAM.

### Noise sources we acknowledge

- **macOS efficiency cores.** Apple Silicon schedules across heterogeneous cores (P + E). Long enough measurements average over both. Short ones don't.
- **GC pauses.** Some scenarios trigger a GC inside the measurement window. With 7 samples × 200k iters this washes out except for the smallest workloads.
- **JIT detection.** `:erlang.system_info(:emu_flavor)` is the right field for this (`:jit` vs `:emu`). `:emu_type` is `:opt` for both JIT and non-JIT builds — I confused these initially and the early bench output incorrectly labeled the machine as "no JIT".

## Reading benchee output (other bench files)

Benchee reports four numbers per scenario:
- **ips** — iterations per second (higher = faster)
- **average** — mean ns/op
- **deviation** — relative std-dev as %
- **median** — middle value, the most trustworthy single number on noisy hardware
- **99th %** — 99th-percentile latency

For sub-µs operations on macOS, **trust the median**, not the mean. Deviation in the thousands of percent is the BEAM/Mac scheduler interaction, not the code under test.

`profile.exs` adds three more numbers per op:
- **bytes/op** — heap bytes allocated (heuristic — see Methodology above)
- **reductions/op** — BEAM's virtual instruction counter. A useful "how much work" proxy; lower = less work
- **GCs** — minor garbage collections triggered in the measurement loop

## Design decisions per op (with evidence)

Every choice below was made because we measured. Where the obvious "fast" technique lost, we kept the slower-looking code that actually won.

### `add` / `sub` / `mult`

- **Public API: struct-based** (`%FastDecimal{coef, exp}`).
- *Measured*: tuple `{coef, exp}` is 5–9 % faster on mult, parity on add (`representation.exs`). Cost is small enough that we pay it for the Inspect protocol, pattern-matching ergonomics, and zero-cost guarantees that hot paths still stay heap-light.
- **No explicit small-int guards.** BEAM's JIT already specializes integer math based on whether values fit in the 60-bit immediate range. Tested an explicit `when c in -2^60..2^60` guard — added ~3 % overhead with **no measurable upside**.

### `div`

- **Pure-Elixir, integer-shift-and-divide with explicit rounding modes.**
- Allocates more than `decimal` (~91 B vs ~8 B) because we materialize the shifted dividend as an intermediate bignum. We accept that — wall time is **5–9× faster** than `decimal` (`profile.exs`).
- A Rust NIF wrapping a native decimal library is faster on div at precision 28 (~2.5× our pure-Elixir path, measured during prototyping). Not adopted because:
  1. It would force a binary dependency on every user
  2. It only wins on this one op
  3. Pure Elixir is still 5× faster than `decimal` here

### `compare`

- **At the BEAM floor: 4 reductions, 0 bytes allocated** (`profile.exs`).
- No optimization possible — it's pattern match + one integer compare + return an atom.

### `parse`

- **Public API uses the char-by-char walker** (`Parser.parse_walk/1`).
- *Measured*: walker is **1.4–3× faster** than the split-and-`binary_to_integer` approach on every input shorter than ~25 digits (`parse.exs`).
- Split wins ONLY on 30+ digit pure-integer strings, where `:erlang.binary_to_integer/1`'s native C loop overtakes BEAM's pattern dispatch.
- Allocates ~186 B per call (sub-binary refs from the recursive head/tail pattern). We accept that — wall time is 3–5× faster than `decimal`, and `decimal` allocates 3× more anyway.

### `to_string`

- **Public API uses `IO.iodata_to_binary([sign, int_part, ?., frac_part])`.**
- *Measured*: a bit-syntax `<<sign::binary, int_part::binary, ?., frac_part::binary>>` alternative was **20 % slower** despite allocating less. `iodata_to_binary` is a NIF that pre-computes total size and allocates once; that beats stepwise binary appends.
- Allocates ~266 B (7× more than `decimal`'s ~36 B) for parity wall time. Tried direct bit-syntax to reduce alloc; that path lost on time. Picking time > alloc here.

### Map construction op: `put_map_assoc` vs `put_map_exact`

- **Kept the `%__MODULE__{coef: ..., exp: ...}` literal-struct form** for all hot paths.
- *Tried*: rewriting to `%{a | coef: c1 + c2}` (Elixir's "strict update") so the BEAM compiler emits `put_map_exact` (updates an existing map's keys) instead of `put_map_assoc` (allocates a fresh map). The bytecode change happened cleanly — module-wide counts flipped from 20:1 `put_map_assoc:put_map_exact` to 7:14, verifiable in `bench/disasm.exs`.
- *Measured*: wall-time unchanged (medians 42 ns both before and after), and the head-to-head head-to-head benchee comparison actually showed `put_map_exact` was **1 % slower** within noise.
- **Conclusion**: BEAMAsm has equally tight implementations of both ops for tiny structs. The literal-struct form is also more readable — every field value is right there at the call site — so the code stays.

### `sum/1` / `product/1`

- **Pure-Elixir reduce via tail-recursive helpers.**
- *Measured during prototyping*: a NIF that received the entire list across the FFI boundary was **6–7× SLOWER** at every list size tested (10 / 100 / 1k / 10k elements).
- Why: Rustler's `Vec<Tuple>` decode marshals each list element across BEAM/Rust (~50–100 ns each). At BEAM's ~11 ns per pure-Elixir add, the marshalling cost can't be recovered.
- Pure-Elixir batch is **26–30× faster than `decimal` reduce** — and crucially, no Rust toolchain needed at install time. The NIF prototype was removed before v1.0; this lesson is preserved.

## Reproducibility notes

- **Hardware matters.** All numbers in the project README are from an M-series Mac on Erlang/OTP 26 with BEAMAsm enabled. Linux on x86 will differ — typically lower absolute numbers but similar ratios.
- **GC noise.** If you see a single scenario with 99th-%ile 100× the median, that's a GC cycle landing inside the measurement window. Re-run to confirm the median.
- **Warmup matters.** Each Benchee scenario uses `warmup: 0.5` to let the JIT specialize and load caches; `time: 2` for the actual measurement window. Don't shorten these — short runs amplify noise.
- **Benchee vs profile.exs.** `profile.exs` uses a tight `:timer.tc` loop without Benchee's per-iteration overhead, so its ns/op numbers are typically lower than `arithmetic.exs`'s. Both are correct, measuring slightly different things.

## When you find a regression

If a change makes any op slower, the contract is: include the bench output in the PR description showing it. If a change makes an op faster, same — show the before/after numbers. The point of having all the benches in-tree is so this conversation is short.
