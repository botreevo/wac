# 0445d — a bare declaration in an `async` function keeps the last pass's value

- **Status:** closed 2026-11-10 (cloud) — `asynclower.wac`'s `Var` arm; `spec/cases/0881`
- **Reported by:** the autonag port ("an uninitialised local in an async loop is the same object every pass")
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** wrong answer

## Reproduction

```wac
import { Ticket } from "core";
Ticket<i32> ready(i32 v) { Ticket<i32> t; t.resolve(v); return t; }
async i32 g() {
  i32 total = 0;
  for (i32 i = 0; i < 3; i++) {
    i32? seen;
    if (i == 0) { seen = 5; }
    total = total + (seen ?? 0);
    await ready(0);
  }
  return total;
}
export i32 f() { return g().wait()!; }
```

`f()` answered 15; without the `await`, 5.

## Why

A machine's locals are cells made once, before anything runs, each holding its type's default. A declaration with an
initialiser became a write into the cell; one without became nothing — "the cell already holds its default", which is
true only on the first pass. After that, `i32? seen;` read whatever the last pass left.

## Fix

A nullable's bare declaration writes `null` into its cell each time it runs: `seen[0] = null;`. Any other type is
assigned before it is read — definite assignment refuses a read before a write — so its bare declaration still needs
nothing. (A first version wrote `T[].defaulted(1)[0]` for every type, which registered a new array type while a body
was being emitted and broke spec case 0534.) A lambda that captured the local is handed a fresh cell instead, as for
any other declaration (`freshCellsForCaptures`).
