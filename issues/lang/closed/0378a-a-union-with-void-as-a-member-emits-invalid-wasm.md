# 0378a — a union with `void` as a member emits invalid wasm, and `Ticket.any` over a `Ticket<void>` is one

- **Status:** closed 2026-11-10 (cloud) — refused at the type and at `Ticket.any`'s call; `spec/cases/0901`, `0902`
- **Claimed by:** wac2
- **Reported by:** agent-a
- **Date:** 2026-10-16
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
import { Ticket } from "core";
export i32 main() {
  Ticket<i32> a;
  Ticket<void> b;
  Ticket<union<i32, void>> r = Ticket.any(a, b);    // AnyValue<(Ticket<i32>, Ticket<void>)>
  b.settleWith(() => {});
  return r.wait().isOk() ? 1 : -1;
}
```

Expected: either an answer, or a refusal naming the construct.
Actual: *the module compiled from … was rejected by the engine*. The smaller form is a local:
`void nothing() { }` then `union<i32, void> u = nothing();` is rejected the same way.

## Notes

**The spec does not say what `union<A, void>` is.** `§wac-void-no-values-uieaw93` says `void` has no
values and cannot be the type of a local, a field, a parameter or an element, and
`§wac-void-typearg-2mkx9db` lets it be a type argument that erases what it stands in for. A union
member is none of those, so `Ticket.any`'s `AnyValue` — the union of what the tickets answer — reaches
a type the spec neither allows nor forbids, and the emitter writes something for it that the engine
refuses. Three answers, which is why this is filed rather than fixed:

1. **Refuse a `void` member** — `Ticket.any` over a `Ticket<void>` becomes a compile error. Honest and
   small, and it costs the obvious use: `await Ticket.any(click, sleep)` where the sleep answers
   nothing.
2. **Drop it in normalisation** — `union<i32, void>` is `i32`. Then a `void` ticket winning answers an
   `i32` that was never produced, which is worse than either other choice.
3. **Make it a member with one value** — `u is void` tests it, and `Ticket.any` answers it when the
   `void` ticket wins. The most useful, and a representation decision for the emitter.

Found building `packages/web`: its `sleep` answered `Ticket<void>`, and `await Ticket.any(event,
sleep)` was the module the engine refused. `sleep` answers `Ticket<f64>` now — the time it fired,
which an animation wants anyway — so nothing there waits on this, and `await Ticket.any(a, b)` as a
statement over non-`void` tickets is case 0547.

## Why

The spec allowed `void` as a type argument and forbade it as a local, field, parameter or element, and said nothing
of a union member — so `union<i32, void>` reached the emitter, which wrote a representation the engine refused.

## Fix

Option 1, decided by the coordinator with wac1: **a `void` member beside any other is refused.**
`checkVoidNullable`, which every written type already passes through, refuses a `union<…>` anywhere in the spelling
with `void` among two or more members — *"void has no values, so it cannot be a member of a union beside another
type"* — after normalisation, so `union<void, void>` is `void` and stands. `Ticket.any` and `anyWithIndex` are
refused **at the program's call** when their tickets mix `void` and a value (`checkAnyOverVoid`): *"Ticket.any over a
void ticket and a valued one has no union to answer — await them separately"*, rather than inside `core`'s
`AnyValue<Ts>`, which names nothing the program wrote. `Ticket.all`, whose `Values<Ts>` is a tuple, is not asked.
`spec/cases/0901` and `0902`.

Found on the way and filed for wac1: `Ticket.any` over **only** `void` tickets, which this leaves legal, already
built a module the engine refused on master — `issues/lang/0448e`.
