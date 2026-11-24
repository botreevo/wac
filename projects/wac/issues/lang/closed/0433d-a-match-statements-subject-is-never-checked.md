# 0433d — a `match` statement's subject is never checked

- **Status:** closed 2026-11-08 (cloud) — `check.wac`'s `checkStmtOnly`, `Match` arm; `spec/cases/0869`
- **Reported by:** wac-sqlite (as "an async function that awaits inside a match arm does not emit")
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** accepted program (then an emit failure, and in a larger program a trap)

## Reproduction

```wac
import { Sys } from "std";
import { flatten } from "core";
export async i32 main(Sys sys) {
  match (flatten(await sys.files().stat("x"))) {
    Ok(st): { await sys.stdout().line("ok"); }
    Err(e): { await sys.stdout().line("err"); }
  }
  return 0;
}
```

`wac check` is clean; the build declines *an assignment between related reference types: never[][] into never[]*.
The `await`s in the arms are not the cause: `stat` answers a plain `Result`, so `flatten` — which takes a
`Result<Result<A, X>, Y>` — cannot be typed. Bound to a local first, the same call is refused. Without the `flatten`
the program builds and runs.

## Why

`checkStmtOnly`'s `Match` arm checked the arms and never the subject; the expression form did. Whatever was wrong
inside a statement's subject passed.

## Fix

The subject is checked, with nothing expected of it. And the refusal says why when an argument has a type of the
wrong shape — *the argument is Result<Stat, …>, which is not the Result<Result<A, X>, Y> this parameter takes* —
rather than only *nothing in the call says what A is*.
