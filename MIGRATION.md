# Migrating from `decimal` to `FastDecimal`

A practical guide. For most codebases, migration is one line. For some, it's a real refactor. This document tells you which one you're in, what to expect, and how to verify the migration is safe.

## Decision tree

Before you touch any code, scan your project:

```bash
# 1. Do you use Decimal.Context.set / with / get / update?
grep -rn "Decimal.Context" lib/ test/

# 2. Do you have %Decimal{...} struct literals (constructing or pattern matching)?
grep -rn "%Decimal{" lib/ test/

# 3. Do you depend on signaling NaN (sNaN) vs quiet NaN distinction?
grep -rn ":sNaN\|signaling" lib/

# 4. Do you read Decimal.Context flags after operations?
grep -rn "Decimal.Context.*flags\|\.flags" lib/

# 5. Do you depend on -0 being distinguishable from 0?
grep -rn "Decimal.new(\"-0\")" lib/
```

| Hits in 1 | Hits in 2 | Hits in 3-5 | Migration difficulty |
|---|---|---|---|
| 0 | 0 | 0 | **Trivial — one-line alias** |
| 0 | A few | 0 | **Easy — mechanical rewrite of struct literals** |
| Some, all `precision: 28` | Any | 0 | **Easy — `precision: 28` is FastDecimal's default too** |
| Non-default precision | Any | 0 | **Real refactor** — thread precision per-call |
| Any | Any | Any | **Probably don't migrate.** `decimal` is the right fit for code that relies on IEEE 754-2008 conformance features. |

Also check for **decimal v2.4 specific API**:

```bash
grep -rn "Decimal\.\(parse\|cast\)\(.*,.*max_\|Decimal\.to_string\(.*,.*max_" lib/ test/
```

If any hit, see section [5](#5-decimalparse2-cast2-to_string3-options--different-protection-model) below — the `:max_digits` and `:max_exponent` options have to be removed (FastDecimal applies similar bounds via global limits instead).

The next sections cover each case in detail.

## The 30-second migration (90% of codebases)

If your project is in the top row of the decision tree:

```diff
 defmodule MyApp.Ledger do
+  alias FastDecimal.Compat, as: Decimal

   def total(items) do
     Enum.reduce(items, Decimal.new(0), fn item, acc ->
       Decimal.add(acc, item.amount)
     end)
   end

   def round_to_cents(d), do: Decimal.round(d, 2, :half_even)
 end
```

That's it. Every `Decimal.*` call in the module routes through `FastDecimal.Compat`, which mirrors `decimal`'s public function surface and auto-coerces inputs (real `%Decimal{}` structs from upstream libs, `%FastDecimal{}`, strings, integers, floats — all accepted).

Add the dep:

```elixir
def deps do
  [
    {:fastdecimal, "~> 1.0"},
    {:decimal, "~> 2.1"}  # keep — Ecto and other libs still pull it in
  ]
end
```

That's the whole migration for typical fintech / ledger / pricing code. The shim adds 5-15% overhead vs calling `FastDecimal.*` directly — usually invisible. If you want to drop the shim later, find-replace `Compat` → `FastDecimal` and verify tests still pass.

## The 5 things that don't translate cleanly

These all stem from documented design differences. Each section covers what changes, what to look for, and how to fix it.

### 1. `%Decimal{...}` struct literals — mechanical rewrite

Structs are module-bound in Elixir, so `alias FastDecimal.Compat, as: Decimal` does **not** make `%Decimal{...}` refer to a FastDecimal struct. The literal will fail to compile under the alias.

**Look for:**

```bash
grep -rn "%Decimal{" lib/ test/
```

**Pattern matching:**

```elixir
# Before:
case decimal do
  %Decimal{sign: -1} -> :negative
  %Decimal{sign: 1, coef: 0} -> :zero
  %Decimal{} -> :positive
end

# After: use predicates instead of pattern matching internals
cond do
  Decimal.negative?(decimal) -> :negative
  Decimal.zero?(decimal) -> :zero
  true -> :positive
end
```

**Construction:**

```elixir
# Before:
%Decimal{sign: 1, coef: 123, exp: -2}
%Decimal{sign: -1, coef: 50, exp: -1}

# After: use the shimmed 3-arg constructor
Decimal.new(1, 123, -2)
Decimal.new(-1, 50, -1)
```

**Effort:** typically 5-20 sites in a typical app. Pure find-and-fix, no logic changes.

### 2. `Decimal.Context.*` — the real blocker

`decimal` carries an implicit per-process precision context that affects every operation. `FastDecimal` deliberately doesn't have one — precision is per-call, only on `div/3`, `sqrt/2`, and `round/3`.

**The danger:** the Compat shim treats `Decimal.Context.set/1`, `.with/2`, `.get/0`, `.update/2` as **no-ops**. Your code continues to compile and run, but **precision silently changes** to FastDecimal's defaults. For a financial system this is a correctness regression, not just a perf change.

**Look for:**

```bash
grep -rn "Decimal.Context" lib/ test/
```

**The good news:** if every `Context.set` you find uses `precision: 28`, you're fine. That's FastDecimal's default too. Drop the `Context.set` calls; the behavior is unchanged.

**The bad news:** if you set non-default precision (typical: `precision: 18` for market-maker style code, `precision: 9` for some FX pricing), every `Decimal.div/2` after that point used the custom precision. You need to thread it per-call:

```elixir
# Before (implicit context):
def init(_) do
  Decimal.Context.set(%Decimal.Context{precision: 18, rounding: :half_even})
  # ... downstream code calls Decimal.div(a, b) with implicit precision: 18
end

# After (explicit per-call):
@precision 18
@rounding :half_even

defp my_div(a, b), do: FastDecimal.div(a, b, precision: @precision, rounding: @rounding)
# ... use my_div instead of Decimal.div throughout
```

The cleanest pattern is a thin wrapper module that bakes in your precision policy:

```elixir
defmodule MyApp.Decimal do
  @precision 18
  @rounding :half_even

  def div(a, b), do: FastDecimal.div(a, b, precision: @precision, rounding: @rounding)
  def sqrt(a), do: FastDecimal.sqrt(a, precision: @precision)
  def round(a, places), do: FastDecimal.round(a, places, @rounding)

  # delegate the rest to FastDecimal — they don't take precision
  defdelegate add(a, b), to: FastDecimal
  defdelegate sub(a, b), to: FastDecimal
  defdelegate mult(a, b), to: FastDecimal
  defdelegate compare(a, b), to: FastDecimal
  # ... etc
end
```

Then `alias MyApp.Decimal` instead of `alias FastDecimal.Compat, as: Decimal`. One line of policy, applied consistently.

**Effort:** depends on how Context is used. If 2-3 `Context.set` calls and dozens of `Decimal.div/2` sites: half a day to write the wrapper and find-replace. If precision varies per code path: more.

### 3. NaN signaling — collapsed

`decimal` distinguishes `:sNaN` (signaling NaN) from `:qNaN` (quiet NaN). Operations on `sNaN` are supposed to raise; on `qNaN` they propagate quietly.

`FastDecimal` collapses both into a single `:nan` value that always propagates quietly.

**What changes:** if any code branches on `coef: :sNaN` vs `coef: :qNaN`, behavior differs silently after migration.

**What to do:** if you don't currently rely on signaling NaN — and almost no Elixir code does — nothing. If you do, document each site and decide whether the simpler model is acceptable.

### 4. Negative zero — collapsed

IEEE 754 distinguishes `-0` from `+0`. `decimal` preserves this distinction.

`FastDecimal` doesn't — `-0` and `0` are both `%FastDecimal{coef: 0, exp: 0}`.

**What changes:** comparisons like `Decimal.compare(d, Decimal.new("-0"))` may behave differently. Specifically, our `compare` will return `:eq` when decimal might return `:lt` for `-0` vs `0`.

**What to do:** grep for `"-0"` in your code. Almost no production code distinguishes -0 from 0; the cases are usually in scientific/IEEE-conformance contexts.

### 5. `Decimal.parse/2`, `cast/2`, `to_string/3` options — different protection model

`decimal` v2.4.0 added `:max_digits` and `:max_exponent` options to `parse/2` and `cast/2`, and `:max_digits` to `to_string/3`. These let *callers* opt into stricter validation:

```elixir
# decimal v2.4:
Decimal.parse("1e1000", max_exponent: 100)        # → :error
Decimal.cast(input, max_digits: 50)               # → :error if too long
```

FastDecimal **doesn't accept these options.** Instead, we apply hardcoded global limits as a defense against CVE-2026-32686-class exponent-amplification DoS attacks (see the [Security](README.md#security) section of the README). The protection is equivalent — both libraries refuse to materialize huge values — we just put the guards in different places:

| | `decimal` v2.4 | FastDecimal |
|---|---|---|
| Default parse limit | `:infinity` (accepts huge inputs as compact structs) | 65,535 (rejects at parse time) |
| Where DoS protection lives | Sticky-bit precision-bounded scaling in `add`/`sub` | `pow10/1` cap raises at operation time |
| Per-call configurability | Yes via `:max_digits`/`:max_exponent` | No (single hardcoded limit) |

**Migration impact:**
- Code using `Decimal.parse/1` or `Decimal.cast/1` (without options) — **works unchanged** under the Compat shim.
- Code using `Decimal.parse/2` with the new options — will hit `UndefinedFunctionError` on `Compat.parse/2`. To migrate, either remove the options (FastDecimal's default limits already protect against the same attacks) or wrap our parser with your own validator if you need stricter-than-default limits.

**Behavioral difference to watch for:** `Decimal.parse("1e100000")` returns `{:ok, ...}` (decimal v2.4 accepts it, only rejects at materialization time); `FastDecimal.parse("1e100000")` returns `:error` (we reject upfront at 65,535). If your code expects `:ok` for very-large-exp inputs that you intend never to materialize, this is a visible change.

### 6. Signal flags and traps — not supported

`Decimal.Context` carries `:flags` (set after operations that triggered conditions like rounding, overflow, inexact, etc.) and `:traps` (which conditions raise vs just set the flag). This is IEEE 754-2008's conformance machinery.

`FastDecimal` has no equivalent.

**What changes:** code that does `Decimal.Context.get().flags` after operations won't work — we have no flags. The Compat shim's `Decimal.Context.get/0` is a no-op.

**What to do:** if you rely on flags, you'll need to track conditions explicitly at the call site (or stay on `decimal`). Cases this matters: enforcing "no inexact results" in audit systems, post-hoc inspection in scientific computing. Almost never in fintech/ledger code.

## Mechanical migration steps

For the common case (top 3 rows of the decision tree):

1. **Add the dep.** `{:fastdecimal, "~> 1.0"}` in `mix.exs`, alongside your existing `:decimal`.

2. **Add the alias to each module that uses `Decimal.*`:**

   ```elixir
   alias FastDecimal.Compat, as: Decimal
   ```

3. **Fix struct literals** if any. `grep -rn "%Decimal{"` and rewrite (see section 1 above).

4. **Decide on `Decimal.Context`.** If you use it with `precision: 28` you can just delete those calls. Otherwise build a wrapper module (section 2).

5. **Swap Ecto types** (if you use Ecto):

   ```diff
    schema "invoices" do
   -  field :total, :decimal
   +  field :total, FastDecimal.Ecto.Type
    end
   ```

   The boundary stays the same — `postgrex` returns `%Decimal{}`, the type converts to `%FastDecimal{}`, and dumps back to `%Decimal{}` on write.

6. **Update `is_decimal`** if you use it:

   ```diff
   -import Decimal.Macros, only: [is_decimal: 1]
   +import FastDecimal, only: [is_decimal: 1]
   ```

   Same shape, same behavior.

7. **Run your test suite.** Use value-equality (`Decimal.equal?/2` via the shim) rather than struct equality (`==`) — `FastDecimal` may represent `1.10` as `{coef: 110, exp: -2}` while keeping the same value, but a struct comparison against decimal's representation would fail. `Decimal.equal?` works correctly across both.

## Verifying the migration

### Correctness

The test for "did I break anything?" is your existing test suite. The shim is value-equivalent to `decimal` for every operation it supports. If a test fails after migration, one of these is true:

- Your test depends on a feature we don't have (Context, sNaN, -0, flags)
- Your test does struct equality (`==`) against a specific representation — switch to `Decimal.equal?/2`
- Your test depends on the default rounding mode being `:half_up` — FastDecimal's direct API uses `:half_even`, but the Compat shim explicitly uses `:half_up` to preserve decimal's default

You can also run the differential test suite from FastDecimal itself against your own decimal-using code, but typically your existing tests are sufficient.

### Performance

`FastDecimal` ships with `mix bench` (one-minute summary table) and 13 bench scripts in `bench/`. To verify *your* workload benefits:

```elixir
# In a test or iex session:
Benchee.run(%{
  "before (decimal)" => fn -> my_workload_using_decimal() end,
  "after (fastdecimal)" => fn -> my_workload_using_fastdecimal() end
}, time: 5, warmup: 2)
```

If your workload is dominated by add/sub/mult/compare/sum, expect 10-30× speedups. If it's dominated by `to_string`, expect parity. Most code is the first kind.

## Real example: 50-line app migration

Suppose this is your code:

```elixir
defmodule Pricing do
  def apply_fee(price, fee_bps) do
    Decimal.mult(price, Decimal.add(Decimal.div(fee_bps, 10_000), 1))
  end

  def spread(bid, ask) do
    diff = Decimal.sub(ask, bid)
    mean = Decimal.add(ask, bid) |> Decimal.div(2)

    diff |> Decimal.div(mean) |> Decimal.mult(10_000) |> Decimal.round(4)
  end
end
```

The migration:

```diff
 defmodule Pricing do
+  alias FastDecimal.Compat, as: Decimal

   def apply_fee(price, fee_bps) do
     Decimal.mult(price, Decimal.add(Decimal.div(fee_bps, 10_000), 1))
   end

   def spread(bid, ask) do
     diff = Decimal.sub(ask, bid)
     mean = Decimal.add(ask, bid) |> Decimal.div(2)

     diff |> Decimal.div(mean) |> Decimal.mult(10_000) |> Decimal.round(4)
   end
 end
```

One line added. Tests still pass. The functions are now ~2× faster (most of the cost is `Decimal.div` which is one of our weaker speedup wins — but `add`, `sub`, `mult` are all 15-20×).

## FAQ

**Q: Will `decimal` keep working as a dep alongside `fastdecimal`?**

Yes. `fastdecimal` requires `decimal` as a dep (for `Decimal.Ecto.Type` boundary conversion and the `Compat` shim's auto-coercion of `%Decimal{}` structs). You can't accidentally end up with one or the other; both are there.

**Q: What about libraries I depend on that return `Decimal`? (Ecto, postgrex, ex_money, etc.)**

They keep working. They return `%Decimal{}` structs at their boundaries; `FastDecimal.cast/1` and the Compat shim's `coerce/1` both accept those. Your code converts at the boundary or uses `FastDecimal.Ecto.Type` to make the conversion automatic for Ecto fields.

**Q: Can I migrate gradually, module by module?**

Yes. The Compat shim and the auto-coercion mean `%Decimal{}` and `%FastDecimal{}` can pass through the same call paths without explicit conversion. Migrate one module, run its tests, repeat.

**Q: What's the rollback story if migration goes wrong?**

Revert the alias. Your code goes back to using `decimal` directly. Nothing else changes. There's no state to clean up.

**Q: Is the Compat shim performance-tested?**

Yes — see `bench/arithmetic.exs`, which includes the `compat` column for every operation. The shim measures 5-15% slower than direct `FastDecimal.*` calls. That's the overhead of the coerce step plus the function indirection.

**Q: I use `Decimal.Macros.is_decimal/1` in guard clauses. Does FastDecimal have an equivalent?**

Yes: `FastDecimal.is_decimal/1`. Same macro shape, same guard-safety. Drop-in rename.

**Q: My code does `Decimal.compare(a, b) == :gt`. Will that still work?**

Yes. `FastDecimal.compare/2` and `FastDecimal.Compat.compare/2` both return `:lt | :eq | :gt | :nan`. The one extra value (`:nan`) only appears when an input is NaN — your existing code probably already handled NaN as an unexpected case.

**Q: My code does `Decimal.to_string(d, :scientific)` — will the output change?**

The output should be the same. Both libraries follow the IEEE 754-2008 "to-scientific-string" rule: compact form when `adjusted_exp >= -6`, scientific form otherwise. We verified this matches `decimal` byte-for-byte in our differential test suite.

If you saw different output before, you may have been on a development build that emitted always-scientific format — v1.0.0 matches decimal.
