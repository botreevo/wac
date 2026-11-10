# 0407a — a `void` type argument does not erase a method's parameter

- **Status:** closed 2026-11-10 (cloud) — `check.wac`'s `erasedArity`; `spec/cases/0905`
- **Reported by:** agent-a
- **Date:** 2026-10-27
- **Kind:** bug
- **Symptom:** compile error

## Reproduction

```wac
import { Ticket } from "core";
export i32 main() {
  Ticket<void> done;
  done.resolve();
  return done.settled() ? 1 : 0;
}
```

Expected: compiles and answers 1. `§wac-void-typearg-2mkx9db` says `void` "erases the parameter it stands in for", and
`Ticket<T>.resolve(T v)` at `T = void` is such a parameter.
Actual: *wrong number of arguments* at `done.resolve()`.

## Notes

The erasure is implemented inside funcref types (`fn<void(T)>` becomes `fn<void()>`, case 0852's neighbours and
`packages/wacc/test/wac/voidtypearg_test.wac`), not for a method's own parameters. `done.settleWith(() => { })` is
the spelling that works today. Found while moving that test off `Pending<void>` (design/system/0013 step 5).

## Fix

The emitter already left an erased parameter out of a method's signature; the checker counted it. Both method-call arity checks now count a method's parameters less each one whose type, substituted for the receiver, is `void`.
