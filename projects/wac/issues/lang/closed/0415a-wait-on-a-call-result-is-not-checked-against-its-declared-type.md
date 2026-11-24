# 0415a — `.wait()` on a call's ticket is not checked against the declared type

- **Status:** closed 2026-11-10 (cloud) — `check.wac`'s `typeOfExpr` answers an owner-free static on a template; `spec/cases/0885`
- **Reported by:** agent-a
- **Date:** 2026-10-28
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
import { Ticket, TicketBase } from "core";
export i32 main() {
  Ticket<i32> a;
  a.resolve(3);
  TicketBase[] parts = [a];
  i32 which = Ticket.first(parts).wait();
  return which;
}
```

Expected: *expected i32, found Result<i32, Stuck>* — which is what `Ticket<i32> t = Ticket.first(parts);
i32 which = t.wait();` says.
Actual: checked clean; the engine rejects `main`: *local.set[0] expected type i32, found call of type (ref
null 23)*.

## Notes

The receiver being a call rather than a local is what hides it. Found porting
`packages/platform/example/patience.wac`; the hang it caused in `patience_test.wac` was the child never
running, with the test's accept unbounded.

## Fix

The receiver being a call was a red herring: `Ticket.first(parts)` had no type at all. `typeOfExpr` answered nothing for every static called on a generic template, because `Box.of(5)` takes its instance from the slot. A static whose signature uses none of the owner's letters (`ownerFree`, ch19) is not that case — `first` answers `Ticket<i32>` whatever `T` is — so its written return type is now the answer, when it has no type parameters of its own.
