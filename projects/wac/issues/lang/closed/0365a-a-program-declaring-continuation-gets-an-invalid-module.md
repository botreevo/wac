# 0365a — A file that declares its own `struct Continuation` and does async work compiles to a module the engine rejects

- **Status:** closed 2026-11-11 (cloud) — `packages/wacc/src/check.wac`'s `isScheduleTarget` and `continuationRenamed`; `spec/cases/0930-a-files-own-continuation-is-not-a-schedule-targets.wac`
- **Reported by:** agent-a
- **Date:** 2026-10-03
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
import { Ticket, TicketBase, Vec } from "core";
struct Continuation {
  TicketBase? t;
  fn<void()> call;
}
export string example() {
  Vec<Continuation> pending;
  schedule pending.push;
  Ticket<i32> input;
  Ticket<i32> r = doubled(input);
  input.resolve(10);
  pending.get(0).call();
  return "\{r.value()}";
}
async i32 doubled(Ticket<i32> t) { return (await t) * 2; }
```

Expected: Either the program's `Continuation` is its own type and this runs, or it is refused with a position; a compiled module is always valid.
Actual: *the module compiled from main.wac was rejected by the engine — this is a compiler bug*.

## Notes

Importing `Continuation` from `core` instead runs (answers 20). A lone `struct Continuation { i32 x; }` with no async work is fine, so it is the scheduler's lowering naming `Continuation` by spelling rather than by core's declaration.

## Fix

The first of the issue's two outcomes was the right one only in the program's eyes: `schedule` takes a `fn<void(Continuation)>` of core's `Continuation`, which is what the lowering hands it, and the checker accepted the parameter by spelling — `Continuation` or `Continuation#<n>` — so a `Vec` of the file's own type went through and the module did not validate. Core's type is renamed `Continuation#<n>` in a file exactly when another file it reaches declares the name, so the bare spelling is core's only when no such rename exists; `isScheduleTarget` asks that, and the refusal says *the `Continuation` declared here is not core's* at the `schedule`. Importing core's `Continuation` instead still runs (20).
