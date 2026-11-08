# 0430d — a program type named as one of `std`'s faults breaks the unions `std` builds from them

- **Status:** open
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
