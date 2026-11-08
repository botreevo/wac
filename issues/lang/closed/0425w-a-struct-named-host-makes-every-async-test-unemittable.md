# 0425w — a struct named `Host` makes every async test unemittable

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `findLambdasExpr`, a method call's receiver by its key; `packages/wacc/test/wac/stdnameshadow_test.wac`
- **Reported by:** wac-kps (filed on its `kps` branch, fixed on master at its request)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
struct Host { i32 x; }
export async string test_x() { await; return ""; }
```

`wac test --allow-read`: *cannot emit — a lambda (this module has 321, 12 in a position the walk does not type
yet …; this one at line 2488:5)* — a line of `std`. `wac check` is clean. A struct named `Channel` met the same.

## Why

`std` builds a `Sys` with `Host.of(…)`, handing it lambdas. The emitter's walk that types lambdas resolves a
static call's receiver to find its parameters, and took the receiver's spelling: `isStructName("Host")`, which
is the program's `Host` when the program declared one first and so holds the bare key. `Host.of` was looked up
on the wrong struct, found nothing, and `std`'s lambdas had no type.

## Fix

The receiver is resolved by its key in the file the call is in (`nameKeyOf`), as the emitter resolves names
everywhere else, and by its spelling only when that finds nothing. The test compiles a program with `std` built
in, since a test file in this repository reads `std` from the tree, which declares it first and hides the bug.

Not fixed by this, and filed as `0430d`: a program type named as one of `std`'s *faults* (`Denied`, `NotFound`,
`Other`, …) still fails, in the unions `std`'s `type` declarations build from them.
