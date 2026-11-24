# 0430d — a program type named as one of `std`'s faults breaks the unions `std` builds from them

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `staticEvalOf` builds the view again when `declCount` has moved; `packages/wacc/test/wac/stdnameshadow_test.wac`
- **Reported by:** cloud session, while closing `0425w`
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

Outside this repository (so `std` is the built-in one), with `wac test --allow-read`:

```wac
struct Denied { i32 x; }
export async string test_x() { await; Denied d = Denied(1); return d.x == 1 ? "" : "bad"; }
```

*cannot emit — a type was registered while a body was being emitted, after the type section had been sized: 7019
counted, 7043 wanted — sig fn[Ticket<Result<u8[],union<Denied, IsDir, …*. The same for `Exists`, `IsDir`, `Loop`,
`NameTooLong`, `NotADir`, `NotEmpty`, `NotFound`, `NotGranted`, `NotRepresentable` and `ReadOnly`; `NoSpace`,
`Other` and `Unsupported` answer *a return between related reference types*. Every other name `std` exports —
`Host`, `Files`, `Socket` and forty more — builds since `0425w`.

## Notes

The names are the members of `std`'s fault unions, `type ReadFault = union<NotFound, Denied, IsDir, …>`, which
the static evaluator computes. The type section is sized with one spelling of a signature mentioning such a union
and a body asks for another, so somewhere a member is spelled by its name rather than its key — the emitter
already hands the static view its own keys (`staticEvalOf`), so it is after that. Workaround: name the type
something else.

## Fix

The cause was the static view, not the union. `staticEvalOf` caches the evaluator's view of the program, with each
declaration's key taken from `Env.declare`, and built it again only when the constants or the imports had grown. Built
while declarations were still being keyed — the program's `Denied` keyed, `std`'s not yet — it answered `std`'s
`Denied` with the program's key, so `std`'s fault unions were spelled with the program's type in them, and spelled
again correctly once the type section had been sized. The view now records how many declarations were keyed when it
was built (`Env.staticDecls`) and is built again when that has moved. Every name `std` exports now builds as a
program's own type.

The test runs the `wac` binary on a file outside the repository: only there is `std` the built-in one, and only
`wac test`'s harness reached the unions this way.
