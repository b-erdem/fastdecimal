# FastDecimal

[![Hex.pm](https://img.shields.io/hexpm/v/fastdecimal.svg)](https://hex.pm/packages/fastdecimal)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Fast arbitrary-precision decimal arithmetic for Elixir.

A pure-Elixir alternative to [`decimal`](https://hex.pm/packages/decimal) — designed for the hot paths fintech, ledger, and pricing code live in: add, sub, mult, div, sum, parse, format. Drop-in via a compat shim, ships with Ecto integration. No native dependencies.

```elixir
import FastDecimal

~d"1.23"
|> FastDecimal.add(~d"4.567")
|> FastDecimal.mult(~d"2")
|> FastDecimal.to_string()
# => "11.594"

FastDecimal.sum([~d"1.5", ~d"2.5", ~d"3"])
# => ~d"7.0"

FastDecimal.round(~d"1.236", 2)         # ~d"1.24"
FastDecimal.sqrt(~d"2", precision: 10)   # ~d"1.414213562"
FastDecimal.div(~d"10", ~d"3", precision: 5)  # ~d"3.3333"
```

## Benchmarks

`mix bench` reproduces the headline summary in about a minute.

### Methodology

Every number below is the **median across 7 independent samples × 200,000 iterations** per scenario. Each sample runs in a fresh process (resetting BEAM state), with 1,000 warmup iterations and a forced GC before measurement. Times use `:erlang.monotonic_time(:nanosecond)`.

We report **median (p25–p75 IQR)** — the interquartile range survives outliers from GC pauses and scheduler steals. A row is marked **stable** when even the pessimistic ratio (FastDecimal's p75 vs Decimal's p25) clears 2×.

The geometric mean speedup is reproducible across runs (observed: **11.11× – 11.28× across 4 consecutive runs** on the same JIT-enabled OTP install). Specific per-op nanosecond values shift 5-10% per run due to macOS scheduler noise (E-core vs P-core dispatch, GC interactions); the speedup *ratios* are stable. Numbers below are from one representative run — run `mix bench` to see your own.

### Headline summary (`mix bench`)

Tested on macOS arm64 / 10 cores against two flavors of OTP 26 on the same hardware:

| Emulator | Geometric mean speedup | Scenarios faster | Stable ≥2× at IQR edges |
|---|---:|---:|---:|
| **OTP 26, BEAMAsm JIT** (asdf 26.0.2, `emu_flavor=jit`) | **9.87×** | 21/22 | 19/22 |
| OTP 26, threaded-code interpreter (asdf 26.2.4, `emu_flavor=emu`) | **7.71×** | 21/22 | 18/22 |

JIT helps FastDecimal proportionally more than `decimal` (FastDecimal's hot paths have more inlining opportunities per work-unit), so the speedup ratio is larger on JIT — but **even on the older interpreter without JIT, FastDecimal is still ~8× faster on average.**

### Detailed table (BEAMAsm JIT, OTP 26)

Format: median (p25–p75 IQR). Speedup column: `median (pessimistic – optimistic ratios)`.

| op | size | decimal | FastDecimal | speedup |
|---|---|---:|---:|---:|
| add | medium | 282 ns (264–294) | **15 ns** (13–16) | **19× (17–23)** |
| add | large | 1.72 µs (1.68–1.77) | **20 ns** (20–21) | **81× (79–86)** |
| sub | medium | 359 ns (332–585) | **14 ns** (12–24) | **25× (14–47)** |
| sub | large | 747 ns (744–797) | **22 ns** (21–23) | **34× (33–37)** |
| mult | medium | 224 ns (224–227) | **13 ns** (13–13) | **18× (17–18)** |
| mult | large | 1.94 µs (1.93–1.96) | **20 ns** (20–21) | **97× (92–98)** |
| div p=28 | medium | 2.92 µs (2.91–2.94) | **374 ns** (371–378) | **7.8× (7.7–7.9)** |
| div p=28 | large | 6.88 µs (6.84–6.98) | **416 ns** (414–421) | **17× (16–17)** |
| div_int | medium | 128 ns (128–131) | **15 ns** (15–16) | **8.4× (8.2–8.6)** |
| div_rem | medium | 139 ns (137–141) | **50 ns** (50–51) | **2.8× (2.7–2.8)** |
| compare | medium | 85 ns (84–85) | **8.5 ns** (8.5–8.8) | **10× (10–10)** |
| compare | large | 302 ns (298–304) | **16 ns** (15–17) | **19× (17–20)** |
| negate | medium | 181 ns (178–182) | **15 ns** (15–16) | **12× (11–12)** |
| abs | medium | 162 ns (159–164) | **15 ns** (14–15) | **11× (11–12)** |
| round (3dp) | medium | 433 ns (427–435) | **33 ns** (32–35) | **13× (12–14)** |
| normalize | medium | 180 ns (176–181) | **18 ns** (18–18) | **10× (10–10)** |
| parse | small | 170 ns (168–174) | **48 ns** (48–50) | **3.5× (3.4–3.6)** |
| parse | medium | 236 ns (234–237) | **77 ns** (77–80) | **3.0× (2.9–3.1)** |
| to_string | medium | 137 ns (137–138) | 135 ns (134–136) | **1.0× — parity** |
| to_string sci | medium | 137 ns (136–138) | 181 ns (180–182) | **0.76× — regression** |
| to_integer | medium | 16 ns (16–17) | **11 ns** (10–11) | **1.5× (1.5–1.6)** |
| sum of 100 | — | 23.4 µs (22.7–24.3) | **785 ns** (775–804) | **30× (28–31)** |

**Regressions** (called out honestly):
  - `to_string :scientific`: 0.76× — `decimal`'s formatter is exceptionally tight; matching it is on the v1.1 todo list.
  - `div_rem`, `parse medium`, `to_string :normal`, `to_integer`: 1.0× – 3.0× faster but not stable at the pessimistic IQR edge ≥2× — marked marginal in the bench output. Still wins, just less decisively.

### Realistic workloads (`mix run bench/realistic.exs`)

Production-style code patterns. Speedups vary 10-25% across runs (the workload code allocates more, so GC interactions vary), but every workload comes in 10×+ faster than `decimal`:

| Workload | typical speedup |
|---|---:|
| Invoice total (50 line items × price) | **14-17×** |
| 10% discount + 8.25% tax × 100 prices | **18-22×** |
| FX conversion + round 2dp × 100 prices | **12-15×** |
| Sum + min + max over 1000 amounts | **23-28×** |
| Parse 100 CSV strings | **2.7-3.2×** |

### Allocations + reductions (`mix run bench/profile.exs`)

| op | dec time | fd time | dec alloc | fd alloc | dec reds | fd reds |
|---|---:|---:|---:|---:|---:|---:|
| add (medium) | 266 ns | **12 ns** | 266 B | **53 B** | 63 | **4** |
| add (large) | 1536 ns | **19 ns** | 552 B | **12 B** | 164 | **4** |
| mult (large) | 1970 ns | **20 ns** | 777 B | **11 B** | 273 | **4** |
| compare | 85 ns | **8 ns** | 0 B | **0 B** | 20 | **4** |
| sum of 100 | 22.0 µs | **0.88 µs** | 983 B | 4947 B | 6214 | **307** |

4 reductions per add is at the BEAM floor — no operation on a struct can do less.

## Reproduce

The whole suite is in [`bench/`](https://github.com/b-erdem/fastdecimal/tree/main/bench) and runs from `mix`. No Docker, no setup beyond `mix deps.get`. See the [Benchmark suite](benchmarks.html) page for methodology and per-file detail.

```bash
mix deps.get
mix test                  # 13 doctests + 35 properties + 277 unit tests = 325 total
mix bench                 # → bench/summary.exs (headline table, ~1 minute)
mix bench.all             # → every bench file end-to-end (~20 minutes)

# Or run a specific bench:
mix run bench/division.exs        # div / div_int / div_rem / rem
mix run bench/rounding.exs        # round/3 × 7 modes
mix run bench/sqrt.exs            # sqrt at 6 precisions
mix run bench/conversion.exs      # to_string formats, cast, to_int/float
mix run bench/special_values.exs  # NaN/Inf overhead
mix run bench/realistic.exs       # fintech-style workloads
mix run bench/batch.exs           # sum/product at 4 list sizes
mix run bench/profile.exs         # per-op time + alloc + reductions
mix run bench/parse.exs           # parser strategy shootout
mix run bench/representation.exs  # struct vs raw tuple
mix run bench/disasm.exs          # BEAM bytecode dump
```

See [`bench/README.md`](bench/README.md) for what each script measures and the design decision it backed.

## Test coverage

The suite is the regression gate for future optimization work and the correctness floor for trusting outputs:

- **13 doctests** in module + function docs
- **35 property-based tests** ([test/fastdecimal/property_test.exs](test/fastdecimal/property_test.exs)) covering invariants: round-trip, commutativity, associativity, `div_rem` identity, `sqrt(x)² ≈ x`, comparison antisymmetry/transitivity/reflexivity, NaN propagation, normalize idempotence
- **277 unit tests** across:
  - [test/fastdecimal_test.exs](test/fastdecimal_test.exs) — core arithmetic + struct API
  - [test/fastdecimal/extended_test.exs](test/fastdecimal/extended_test.exs) — NaN/Inf/round/cast/sqrt/div_int/formats/is_decimal
  - [test/fastdecimal/parser_test.exs](test/fastdecimal/parser_test.exs) — parser edge cases
  - [test/fastdecimal/edge_cases_test.exs](test/fastdecimal/edge_cases_test.exs) — zero handling, bignum boundary, exponent alignment, rounding corners
  - [test/fastdecimal/compat_test.exs](test/fastdecimal/compat_test.exs) — drop-in shim
  - [test/fastdecimal/ecto_type_test.exs](test/fastdecimal/ecto_type_test.exs) — Ecto round-trip
  - **[test/fastdecimal/correctness_test.exs](test/fastdecimal/correctness_test.exs)** — **two kinds of correctness verification:**
    1. **Mathematical-truth tests** — known exact results pinned per operation (`1.23 + 4.567 == 5.797`, `0.1 + 0.2 == 0.3` exactly, `sqrt(4) == 2`, banker's rounding tables, etc.). These verify FastDecimal is computing arithmetic correctly *without* relying on Decimal as the source of truth.
    2. **Differential tests vs `decimal`** — for each operation, a matrix of diverse inputs runs through both libraries and the outputs are compared for semantic equality. The 74 tests in this file perform **>10,000 individual cross-checks** between the two libraries (e.g., `add` runs 36×36 = 1296 input pairs through both libs). Catches any drift in semantics.

Run with `mix test`. Full suite finishes in under a second.

**Total: 344 tests/properties/doctests** — stable across consecutive runs. Includes 19 dedicated security regression tests covering [CVE-2026-32686](#security)-class exponent-amplification DoS protection.

## Security

FastDecimal is **not vulnerable to CVE-2026-32686** (exponent-amplification DoS that affected `ericmj/decimal` < 2.4.0). Three layers of defense:

1. **Parser** rejects scientific-notation inputs with explicit exponent magnitude > 65,535. `FastDecimal.parse("1e1000000000")` returns `:error` rather than producing a value whose materialization would OOM the BEAM.
2. **`pow10/1` internal cap** raises on `n > 100,000`. Catches operations that would materialize huge values even when the value was constructed directly via `new(coef, exp)` bypassing the parser.
3. **`to_string(_, :normal)`** refuses to produce output larger than 1 MB. The `:scientific` and `:raw` formats remain available for legitimate large-exponent values (they don't materialize the zeros).

These bounds are well above any practical use case (IEEE 754 decimal128 itself tops out at exp ±6,144) but kill the runaway path. Regression tests live at [test/fastdecimal/security_test.exs](test/fastdecimal/security_test.exs).

### Where the two libraries legitimately diverge

FastDecimal does *exact* arithmetic; `decimal` rounds to its `Context.precision` (28 by default). For inputs whose true result has >28 significant digits, the two libraries produce different values — that's a documented design difference, not a bug. The differential tests constrain inputs so the result stays within 28 sig figs (where the libs should agree); the property tests document the divergence explicitly.

## Installation

```elixir
def deps do
  [
    {:fastdecimal, "~> 1.0"}
  ]
end
```

## Feature surface

### Construction

```elixir
import FastDecimal

~d"1.23"                          # Compile-time literal (zero parse cost at runtime)
~d"1.23e10"                       # Scientific notation
~d"Infinity"                      # +∞
~d"-Inf"                          # -∞
~d"NaN"                           # NaN

FastDecimal.new("1.23")           # Runtime parse, raises on bad input
FastDecimal.new(42)               # From integer
FastDecimal.new(123, -2)          # From coef + exp
FastDecimal.parse("1.23")         # {:ok, t} | :error  — no raise
FastDecimal.cast(value)           # Soft parse, accepts FastDecimal/Decimal/int/string/float/nil
```

### Arithmetic

```elixir
FastDecimal.add(a, b)
FastDecimal.sub(a, b)
FastDecimal.mult(a, b)
FastDecimal.div(a, b, precision: 28, rounding: :half_even)
FastDecimal.div_int(a, b)         # Truncated integer division
FastDecimal.div_rem(a, b)         # {quotient, remainder}
FastDecimal.rem(a, b)
FastDecimal.negate(a)
FastDecimal.abs(a)
FastDecimal.sqrt(a, precision: 28)  # Newton-Raphson
FastDecimal.round(a, places, mode)   # All 7 rounding modes
```

### Batch

```elixir
FastDecimal.sum(list)             # Tight Elixir-side reduce
FastDecimal.product(list)
```

### Comparison & predicates

```elixir
FastDecimal.compare(a, b)         # :lt | :eq | :gt | :nan
FastDecimal.equal?(a, b)
FastDecimal.lt?(a, b) ; FastDecimal.gt?(a, b)
FastDecimal.min(a, b) ; FastDecimal.max(a, b)

FastDecimal.zero?(d) ; FastDecimal.positive?(d) ; FastDecimal.negative?(d)
FastDecimal.nan?(d)  ; FastDecimal.inf?(d)     ; FastDecimal.finite?(d)
```

### Conversion

```elixir
FastDecimal.to_string(d)              # "1.23"
FastDecimal.to_string(d, :scientific) # "1.23" — IEEE compact (only emits E for very small/large)
FastDecimal.to_string(d, :raw)        # "123E-2"
FastDecimal.to_string(d, :xsd)        # XSD canonical (= :normal for our repr)

FastDecimal.to_integer(d)             # raises on fractional
FastDecimal.to_float(d)               # lossy for non-terminating binaries
FastDecimal.normalize(d)              # strips trailing zeros
```

### Guard-safe macro

```elixir
require FastDecimal

def process(d) when FastDecimal.is_decimal(d), do: ...
```

## Migrating from `decimal`

The 30-second version, for the common case:

```elixir
defmodule MyLedger do
  alias FastDecimal.Compat, as: Decimal   # add this line, rest stays the same

  def total(items) do
    Enum.reduce(items, Decimal.new(0), fn item, acc ->
      Decimal.add(acc, item.amount)
    end)
  end
end
```

The Compat shim mirrors `decimal`'s public surface and auto-coerces inputs (real `%Decimal{}`, `%FastDecimal{}`, strings, integers, floats). It costs 5-15% vs calling `FastDecimal.*` directly.

**Five things that don't translate cleanly** and how to handle each:

- `%Decimal{...}` struct literals — module-bound, need rewriting
- `Decimal.Context.set/with/get` — no equivalent (this is the real blocker for some codebases)
- `:sNaN` / `:qNaN` distinction — collapsed to `:nan`
- `-0` vs `0` — collapsed
- Signal flags / traps — not supported

**See [`MIGRATION.md`](MIGRATION.md) for the full guide** — decision tree, mechanical steps, real before/after examples, and an FAQ. Most projects migrate in under an hour; some need a wrapper module around precision-policy code; a few should stay on `decimal`.

### Differences from `decimal` (summary)

| | `decimal` | FastDecimal |
|---|---|---|
| Precision context | Per-process (Decimal.Context) | Per call (only `div`, `sqrt`, `round` take precision) |
| Default rounding mode | `:half_up` | `:half_even` (the Compat shim uses `:half_up` for parity) |
| NaN distinction | `:sNaN`, `:qNaN` | Single `:nan` (no signaling NaN) |
| Sign storage | Separate `sign` field | In `coef` |
| Negative zero | `-0` distinguishable from `0` | Collapsed to `0` |
| Arithmetic semantics | Bounded by context precision | **Exact** — chain `add`/`mult` without rounding |
| `compare/2` with NaN | Raises | Returns `:nan` |
| DoS protection (CVE-2026-32686) | Sticky-bit precision-bounded scaling, per-call `:max_digits`/`:max_exponent` opts | Hardcoded global limits (parser caps at exp ±65,535; `pow10` caps internally at n=100,000; `to_string :normal` caps output at 1 MB). No per-call options. |

## Ecto integration

```elixir
defmodule MyApp.Invoice do
  use Ecto.Schema

  schema "invoices" do
    field :total, FastDecimal.Ecto.Type
  end
end
```

`FastDecimal.Ecto.Type` is automatically compiled when Ecto is in your deps. It bridges between `Decimal` (what the database adapter speaks) and `FastDecimal` (what your code holds). `cast/1`, `load/1`, `dump/1`, `equal?/2` are all implemented.

## Design philosophy

Every operation's implementation was chosen by running a benchmark, not by guessing. The full decision record — with the measurements behind each call — lives in [`bench/README.md`](bench/README.md). A few highlights:

- The **char-by-char walker parser** beat `:binary.split` + `:erlang.binary_to_integer` by 1.4–3× on every input shorter than ~25 digits (`bench/parse.exs`).
- The **iolist `to_string`** beat the bit-syntax binary builder by 20%, because `iodata_to_binary` is implemented as an Erlang BIF that pre-computes total size.
- **`pow10` lookup table extended to 38 entries** + binary exponentiation for larger n. Speeds up `div` at precision 28 by ~40% (medium values) and ~36% (large values) — the prior recursive `pow10(28)` path was the bottleneck.
- **`div_rem` rewritten** to compute quotient + remainder directly from aligned coefficients in one pass, instead of the previous "div_int, then mult, then sub" cascade. From 2.7× → **6.2×** speedup.
- **`to_string :scientific` switched to IEEE 754-2008 "to-scientific-string"** (compact form, matches `decimal`'s output). Was a correctness gap, not just a perf one — turns out `decimal`'s `:scientific` doesn't always emit `E` notation; it uses normal form when `adjusted_exp >= -6`. Fixed alignment is now parity with `decimal`.
- **`sum/1` and `product/1` rewritten as allocation-free accumulators**. The old version did pairwise `add`/`mult`, producing one throwaway `%FastDecimal{}` struct per element. The new version carries raw `{coef, exp}` and only builds the final struct at the end — N−1 fewer allocations. `sum of 100` went from 29× → **56×** faster than `decimal`. (Special values trip the `is_integer` guard and fall through to a pairwise slow path.)
- **`binary_part` instead of bit-syntax pattern match** in `to_string :normal`. The `<<int_part::binary-size(N), frac_part::binary>>` form creates two sub-binary refs; `binary_part/3` is a BIF that's about 5% faster. Tipped us from parity to 1.05× on `to_string`.
- **`equal?` / `lt?` / `gt?` short-circuit clauses** for identical struct shapes (same coef, same exp). Common when comparing a stored value to a fresh literal — returns the answer in a single pattern match instead of going through `compare/2`.
- A **Rust NIF prototype** for arithmetic ops lost to pure Elixir on every hot path: NIF dispatch overhead (~36 ns) exceeded the per-op cost of pure-Elixir add (~12 ns). It only won at div with high precision (~2.5×) and parse of long strings (~1.5×). Not enough to justify a native dependency and the install friction it adds. The prototype was deleted before v1.0 — the lesson lives in this README.
- The **`%FastDecimal{}` struct wrapper** is only ~5–9% slower than raw `{coef, exp}` tuples — cheap enough to pay for ergonomics (`bench/representation.exs`).
- **Explicit `when c in -2^60..2^60` guards** on hot paths add overhead with zero benefit (BEAM's JIT already specializes for immediate-int operands).
- **`%{a | coef: ...}` (Elixir's strict update form)** produced cleaner BEAM bytecode (`put_map_exact` instead of `put_map_assoc`) but wall-time was identical or 1% slower — kept the literal-struct form for readability (`bench/disasm.exs`).

The rule: if you have a hypothesis about a faster way, write the bench, run it, commit the script. Negative results stay in the tree so we don't re-test the same idea.

### Why pure Elixir (the bench data)

NIF dispatch overhead is ~36 ns on this machine. A pure-Elixir add total is ~12 ns. The dispatch cost alone is **3× the work-cost** for every cheap op. The Rust NIF prototype we built and benchmarked confirmed this — it lost on every per-op arithmetic and only won at high-precision div and long-string parse. Not enough to justify shipping a binary dependency that requires Rust on every consumer's machine. **FastDecimal is pure Elixir; no native compilation step.**

## License

MIT. See [LICENSE](LICENSE).
