# Changelog

All notable changes to FastDecimal.

## 1.0.0 — 2026-05-13

Initial release. Feature parity with `ericmj/decimal` except the implicit
`Decimal.Context` (intentional design decision — see `FastDecimal` moduledoc).

### Features

- **Struct API** — `%FastDecimal{coef: integer | :nan | :inf | :neg_inf, exp: integer}`
- **Sigil** — `~d"1.23"` for compile-time literals (zero runtime parse cost)
- **Special values** — NaN, +Infinity, -Infinity with IEEE-style propagation through all ops
- **Arithmetic** — `add/2`, `sub/2`, `mult/2`, `div/3`, `div_int/2`, `div_rem/2`, `rem/2`, `negate/1`, `abs/1`, `sqrt/2`
- **Batch** — `sum/1`, `product/1` (~26-30× faster than `Enum.reduce(_, _, &Decimal.add/2)`)
- **Comparison** — `compare/2`, `equal?/2`, `lt?/2`, `gt?/2`, `min/2`, `max/2`
- **Predicates** — `zero?/1`, `positive?/1`, `negative?/1`, `nan?/1`, `inf?/1`, `finite?/1`
- **Rounding** — `round/3` with all 7 rounding modes (`:half_even`, `:half_up`, `:half_down`, `:down`, `:up`, `:floor`, `:ceiling`)
- **Conversion** — `to_string/2` with `:normal`, `:scientific`, `:raw`, `:xsd` formats; `to_integer/1`, `to_float/1`, `normalize/1`
- **Parsing** — `new/1`, `parse/1`, `cast/1` (soft). Accepts decimals, scientific notation (`1.23e10`), and special-value strings (`"NaN"`, `"Infinity"`, `"-Inf"`).
- **Guards** — `is_decimal/1` macro for guard clauses
- **Compat shim** — `FastDecimal.Compat` mirrors `Decimal`'s function signatures; drop-in via `alias FastDecimal.Compat, as: Decimal`
- **Ecto integration** — `FastDecimal.Ecto.Type` implements `Ecto.Type` (auto-compiled when Ecto is present)

### Performance vs `ericmj/decimal` v2.4 (M-series Mac, OTP 26, BEAMAsm)

Geometric mean speedup across 22 op/size scenarios: **~10×** (range across 6
runs: 9.67–10.01×). Full table and methodology in [README.md](README.md) and
[bench/README.md](bench/README.md); reproduce with `mix bench`.

Highlights (tight-loop medians, BEAMAsm JIT):

| Op (medium values) | decimal | FastDecimal | speedup |
|---|---:|---:|---:|
| add / sub / mult | ~250 ns | ~13 ns | **~20×** |
| compare | ~85 ns | ~8.5 ns | **~10×** |
| div (p=28) | ~3.0 µs | ~380 ns | **~8×** |
| round (3dp) | ~430 ns | ~33 ns | **~13×** |
| parse | ~230 ns | ~77 ns | **~3×** |
| **sum of 100** | ~22 µs | ~0.8 µs | **~27×** |

Large values (~10^14) widen the arithmetic gap to **70–100×** because
decimal's BigInt allocation cost dominates while FastDecimal stays in the
60-bit immediate-int range longer.

Known regression: `to_string(_, :scientific)` at 0.76× — `decimal`'s
hand-rolled formatter is exceptionally tight. Tracked for v1.1.

On non-JIT BEAM (older threaded-code interpreter), geomean speedup drops to
**~7.7×** — the JIT amplifies our advantage but doesn't create it.

### Correctness verification

- **13 doctests + 35 property tests + 277 unit tests = 325 total**, all green.
- The correctness suite ([test/fastdecimal/correctness_test.exs](test/fastdecimal/correctness_test.exs)) performs >10,000 individual cross-checks between FastDecimal and Decimal across diverse input matrices for every operation. It also pins known exact mathematical results per operation (e.g., `0.1 + 0.2 == 0.3` exactly, `sqrt(4) == 2`, full banker's rounding tables) — verifying correctness *without* relying on Decimal as the source of truth.
- Property tests cover invariants: round-trip, commutativity, associativity, `div_rem` identity (`a == q·b + r`), `sqrt(x)² ≈ x`, comparison antisymmetry/transitivity/reflexivity, NaN propagation, normalize idempotence.

### Design choices documented

- Exact arithmetic. `add` / `sub` / `mult` / `sum` / `product` never round.
- Per-call precision (only `div/3`, `sqrt/2`, `round/3` take a precision arg).
- No `Decimal.Context` — would erase the speedup; specify precision per call.
- No separate sign field — sign lives in `coef`.
- No NaN signaling distinction (`sNaN`/`qNaN` collapsed to one `:nan`).
- Pure Elixir core, no native compilation step. A Rust NIF was prototyped,
  benchmarked, and **rejected** for nearly every op (per-op NIF dispatch
  ≈ 36 ns ≥ BEAM-side add ≈ 42 ns). The prototype was deleted before v1.0;
  the design rationale is preserved in README.md and bench/README.md.
