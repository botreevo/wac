# 0360a — a literal converted through `fromNumber` is one shared object

- **Status:** closed 2026-11-10 (cloud) — Andrew's decision: converted afresh where it can be written through; `spec/cases/0916`, `0917`
- **Reported by:** agent-a
- **Date:** 2026-10-03
- **Kind:** bug
- **Symptom:** wrong answer

## Reproduction

```wac
import { NumberLiteral, fromNumber, Result } from "core";
struct Box {
  i32 v;
  Result<Box, string> [fromNumber](NumberLiteral n) { return Result.Ok(Box(7)); }
}
export i32 twice() {
  i32 total = 0;
  for (i32 i = 0; i < 2; i++) {
    Box b = 3;                 // a literal, written once and evaluated twice
    total = total + b.v;
    b.v = 100;
  }
  return total;                // 7 + 7 = 14 expected
}
```

Expected: `14` — each evaluation of `Box b = 3;` is a value of its own.
Actual: `107` (`wac run`, 2026-10-03) — the second iteration sees the first one's write.

## Notes

`lowerFromNumberLiterals` turns each converted literal into a static, `static Box @"$lit_L_C" =
literalValue(Box.[fromNumber](…))`, computed once at compile time (spec ch09 says *"The compiler
calls it statically, once per literal"*). For a number or an immutable value that is exactly right. For a
struct the program can write to, every evaluation of the literal binds the same object.

The `const`-as-type change (spec ch17) made this visible: a static is `const`, so `Box b = 3;` was
refused as a `const Box` becoming a `Box`. The checker exempts the `$lit_` statics for now
(`constExpr` in `packages/wacc/src/check.wac`) so ch09's examples keep working, which keeps the sharing.

Two ways out, and the choice is the spec's: a converted literal is `const` (so `Box b = 3;` needs
`const Box b = 3;`), or the static holds the *converted value's ingredients* and each evaluation builds a
fresh object. The second needs a copy the language does not have for an arbitrary struct.

## Decision

Andrew's, 2026-11-10, on the third answer rather than either the issue offered: neither *a converted literal is
`const`* nor *the static holds ingredients*, but **convert again at each evaluation** — `[fromNumber]` called at run
time, no copy operation needed — **where the value can be written through**, and the static value everywhere else,
which no program can tell apart. The compile-time refusal of an `Err` stays.

## Fix

`lowerFromNumberLiterals` (`packages/wacc/src/api.wac`) still makes the static for every converted literal — it is
what static evaluation runs, and so what refuses an `Err` at the literal. A use whose target is a struct or array in a
slot that is not `const` now reads `literalFresh(static, T.[fromNumber](NumberLiteral("3")), "3")` (`core/number.wac`):
it converts again and answers that, and takes the static only so a build does not prune it, and the refusal with it.
Any other use reads the static as before. `NumberLiteral` carries nothing from the run, so a conversion that succeeded
statically succeeds again. The checker's `$lit_` exemption in `constExpr` is gone: the static is `const`, and nothing
that reads it directly is a slot it could be written through. Spec ch09's rule is rewritten under a new tag,
`[§wac-fromnumber-evaluation-5k2r8vq]`, with `§wac-fromnumber-static-ah2ihmk` recorded in appendix D.

The issue's program answers 14; `spec/cases/0916` holds it, `0917` holds a `const` slot reading the static, and a
literal whose conversion answers `Err` is still *"trap: the literal 3 cannot be converted: its `fromNumber` answered
Err"* at the literal. Cases 819/819 and the spec examples (220, 149, 144 — unchanged) are met.
