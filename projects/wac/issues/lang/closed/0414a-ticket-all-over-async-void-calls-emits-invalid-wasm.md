# 0414a — `Ticket.all` over `async void` calls emits invalid wasm

- **Status:** closed 2026-11-10 (cloud) — `emit.wac`: a store into a `void` tuple member stores nothing; `spec/cases/0890`
- **Reported by:** agent-a
- **Date:** 2026-10-28
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
import { Sys, Output } from "std";
import { Ticket } from "core";
export async i32 main(Sys sys) {
  Output out = sys.stdout();
  await Ticket.all(nothing(out, "a"), nothing(out, "b"));
  return 0;
}
async void nothing(Output out, string s) { out.line(s); }
```

Expected: prints `a` and `b`.
Actual: the engine rejects a lambda: *not enough arguments on the stack for struct.set (need 2, got 1)*.

## Notes

`Values<Ts>` of two `void`s is the likely shape: `all`'s `drive` builds `v.[i] = tickets.[i].value()` and a
`void` member has no value to put. Found porting `packages/platform/example/pipe.wac`, which now starts its
legs and awaits them one by one instead.

## Fix

`all`'s `drive` stores `tickets.[i].value()` into each member of `Values<Ts>`, and for a `void` ticket both are `void`:
the emitter wrote a `struct.set` with nothing on the stack to set. A store into a `void` tuple member now runs its right
side and stores nothing. (A `static_if` in `all` skipping the store was tried first; it hid the `value()` calls from the
instance scan, and two corpus cases lost their instances.)
