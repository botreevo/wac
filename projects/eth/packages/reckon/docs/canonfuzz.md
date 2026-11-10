# The NaN rewrite, checked against itself

`src/canon.wac` makes a module's NaNs canonical (WebAssembly 3.0's deterministic profile) by checking the result of every
float operation that can produce a NaN, except where a hand-written model of the stack and locals shows no one can see
that NaN's bits (consumed by another producer, a comparison, an int conversion, `drop`, or a local only ever used that
way). A mistake in that model would let an engine's own NaN through, and nothing would notice: the module still runs and
validates. `tools/canonfuzz.sh` (`wac task reckon:canonfuzz`) is the check that notices.

## How

Each module is rewritten twice: as the runner does (elided), and with every producing operation checked (`canon --all`,
the reference). Each version is run on V8 and on wasmtime, and all four runs must print the same thing. The modules are
60 random programs from `tools/canonfuzz.py` (seeded, so a failure reproduces) and the corpus's `floats` and `nanpaths`.
The generator starts from NaNs of every kind (0/0, inf−inf, √−x, payloads, negative and signalling ones) and mixes them
through everything the model reasons about: chains of arithmetic, locals reassigned and reread, loops, branches, `?:`,
arrays, struct fields (built and assigned), helper calls and returns, neg/abs/copysign, f32 round trips, comparisons and
guarded int conversions. Every variable, array slot and struct field is printed bit for bit.

## What it shows (2026-11-10)

- The model as it stands: **62 of 62 agree** on both engines, elided and full.
- With no rewrite at all, all 62 print something else (x86's sign bit on `0/0`, V8's and wasmtime's different choices).
  So a model that elided everything would fail every one.
- **Six deliberate model mistakes, each caught:**

| mistake planted in the model | programs that catch it |
| --- | --- |
| `neg`/`abs` lose track of where a value came from | 3 of 22 |
| `copysign` hides its sign operand | 4 of 22 |
| a reinterpret (`toBits`) hides its operand | 19 of 22 |
| `array.set` hides the stored value | 9 of 22 |
| `struct.set` hides the stored value | 6 of 62 (1 of 62 until the generator assigned fields) |
| `local.set` into any local hides | 22 of 22 |

## Limits

- The generator writes wac, so only what wac's compiler emits is exercised. Linear-memory stores (`f64.store`), which
  wac programs do not use for floats, and SIMD (refused by the rewrite) are not covered.
- A mistake that only matters in a shape the generator never produces would pass. The weakest row above is the measure:
  a rarely generated shape is caught rarely. Raising the count (`canonfuzz.sh DIR 500`) buys more.
