# Changelog

All notable changes to FastDecimal.

## 1.0.1 — 2026-05-13

### Performance

- **Parser 4-byte fast path** in `FastDecimal.Parser.parse_walk/1` (used by
  `new/1` and `parse/1`). Multi-digit integer and fractional runs now consume
  4 bytes per recursive call instead of 1. Bench impact:
  - `parse "1234.56789"` (medium): **123 ns → 65 ns** (1.9× faster), bumping
    the speedup over `decimal` from 1.94× to 3.7× (now stable at IQR edges).
  - `parse "1.23"` (small): unchanged within bench noise.
  - Longer numeric strings benefit proportionally — the win scales with
    significant-digit count.

### Internal hygiene

- Added `@spec` coverage to every public function in `FastDecimal.Compat`
  (the drop-in `alias FastDecimal.Compat, as: Decimal` migration shim).
  Improves Dialyzer / IDE / tooling support for migrators.
- Marked `FastDecimal.Parser.parse_walk/1` and `parse_split/1` as
  `@doc false` — they're `def` (not `defp`) only because `bench/parse.exs`
  and `test/fastdecimal/parser_test.exs` reach into them for the strategy
  shootout. The doc tag makes the intent explicit.
- Removed a dead `isqrt(0)` clause in `sqrt/2`. Caller already filters
  `coef: 0` directly, so the clause was unreachable. Dialyzer-clean.
- Added zero-coefficient short-circuits to `to_integer/1` and `to_float/1`.
  `to_integer(%FastDecimal{coef: 0, exp: -1_000_000_000})` now returns `0`
  instead of tripping the pow10 cap. (Mirrors the decimal v2.4.1 fix
  philosophy — `0 × 10^anything` is always `0`, so don't bother
  materializing the alignment factor.)

### Documentation

- MIGRATION.md section 5 now covers both `decimal` v2.4 (opt-in `:max_digits`/
  `:max_exponent`) and v3.0+ (IEEE 754 decimal128 defaults) migration paths.
- Updated decision-tree grep to catch `Decimal.new/2` with opts (added in
  `decimal` v3.1.0).

### Infrastructure

- GitHub Actions CI: matrix test across Elixir 1.15/OTP 26 (minimum),
  1.17/OTP 27, 1.18/OTP 28 (latest); `mix format --check-formatted` and
  Dialyzer jobs; PR-only `mix bench` smoke test that catches bench-script
  rot but explicitly does not gate on Actions-runner timing noise.

## 1.0.0 — 2026-05-13

Initial release. Feature parity with `ericmj/decimal` except the implicit
`Decimal.Context` (intentional design decision — see `FastDecimal` moduledoc).

### Security

- **Not vulnerable to CVE-2026-32686** (exponent-amplification DoS that
  affected `decimal` < 2.4.0). FastDecimal mitigates with three layers:
  - **Parser layer** ([`FastDecimal.Parser`](lib/fastdecimal/parser.ex)):
    explicit exponents in scientific notation are capped at ±65,535. Inputs
    like `"1e1000000000"` from untrusted sources return `:error` rather
    than landing as a `%FastDecimal{}`.
  - **`pow10/1` cap** (defense in depth): any internal `pow10` call with
    `n > 100_000` raises `ArgumentError`. Catches the DoS at every
    operation that would materialize a large-exponent value (add/sub with
    huge gap, compare across huge gap, etc.) — even when the value was
    constructed directly via `new/2` bypassing the parser.
  - **`to_string :normal` cap**: output >1 MB raises. `:scientific` and
    `:raw` formats remain available for legitimate extreme-exp values.
- See `test/fastdecimal/security_test.exs` for regression tests covering
  each layer.

### Notable semantic difference vs prior internal versions

- `to_string(d, :scientific)` now follows IEEE 754-2008's "to-scientific-string"
  rule (same as `decimal`): use normal form when `adjusted_exp >= -6`, scientific
  form only when very small/large. Previously emitted scientific form always.
  This matches what `decimal` produces and is what most callers expect.

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

Geometric mean speedup across 22 op/size scenarios: **~11.2×** (range
observed across consecutive runs: 11.11×–11.28×). FastDecimal wins on
**22/22 scenarios** in most runs; `to_string` ops hover at parity and may
flip to 21/22 ±1 op based on macOS scheduler noise. Full table and methodology in [README.md](README.md) and
[bench/README.md](bench/README.md); reproduce with `mix bench`.

Highlights (tight-loop medians, BEAMAsm JIT):

| Op (medium values) | decimal | FastDecimal | speedup |
|---|---:|---:|---:|
| add / sub / mult | ~250 ns | ~13 ns | **~20×** |
| compare | ~85 ns | ~8.5 ns | **~10×** |
| div (p=28) | ~3.0 µs | ~234 ns | **~13×** |
| div_rem | ~137 ns | ~22 ns | **~6×** |
| round (3dp) | ~430 ns | ~33 ns | **~13×** |
| parse | ~235 ns | ~78 ns | **~3×** |
| **sum of 100** | ~22 µs | ~0.4 µs | **~55×** |

Large values (~10^14) widen the arithmetic gap to **70–100×** because
decimal's BigInt allocation cost dominates while FastDecimal stays in the
60-bit immediate-int range longer.

`to_string(_, :normal)` and `to_string(_, :scientific)` are at parity
(~1.0×); decimal's formatter is exceptionally tight. `to_integer` is 1.6×
faster but the op is so cheap (~10 ns) that scheduler noise dominates the
pessimistic IQR edge. No other op is below 2× in our measured set.

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
