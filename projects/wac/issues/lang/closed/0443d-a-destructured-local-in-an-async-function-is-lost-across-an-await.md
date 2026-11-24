# 0443d — a destructured local in an `async` function is lost across an `await`

- **Status:** closed 2026-11-10 (cloud) — `asynclower.wac`'s `splitDestructure`; `spec/cases/0878`
- **Reported by:** cloud session — `tools/wac/matrixfuzz.wac`, its first run
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
import { Ticket } from "core";
Ticket<i32> ready(i32 v) { Ticket<i32> t; t.resolve(v); return t; }
async i32 g() {
  (i32 a, i32 b) = (3, 4);
  await ready(0);
  return a * b;
}
export i32 f() { return g().wait()!; }
```

`wac check` is clean; the build says *`a`, which is read here and is neither a local nor a module constant this
emitter can find*.

## Why

An `async` body becomes a state machine whose locals are cells declared before anything runs. The plan hoists every
`Var` it finds at any depth, and a destructuring is not a `Var`: its bindings stayed plain locals inside one state, so
the read after the `await`, in another state, named nothing.

## Fix

In a machine, `(T a, U b) = e;` is taken apart first as `X t = e; T a = t.0; U b = t.1;` — a temporary and one `Var`
per member, which the plan hoists like any other. A nested group is one more temporary. A binding with no written
type is typed `typeof(t.k)`; the temporary takes the pattern's types, position by position over a tuple written out,
since `typeof((3, 4))` has no type for its literals. `awaitTokens` reserves four temporaries per `) =`.
