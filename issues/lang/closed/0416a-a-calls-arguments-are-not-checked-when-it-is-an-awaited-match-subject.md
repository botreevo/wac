# 0416a — a call's arguments are not checked when it is the awaited subject of a `match`

- **Status:** closed 2026-11-10 (cloud) — already fixed on master; refused by the checker; `spec/cases/0897`
- **Reported by:** agent-a
- **Date:** 2026-10-28
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
import { Sys, Launch } from "std";
export async i32 main(Sys sys) {
  match (await sys.procs().exec("true", string[](), u8[](), string[](), Launch.plain())) {
    Ok(e): { return 0; }
    Err(f): { return 1; }
  }
}
```

Expected: *argument does not match the parameter's type — expected ChildEnv, found string[]*, which is what
`auto r = await sys.procs().exec(…same…);` says.
Actual: checked clean; the module is invalid (*call[4] expected type (ref null 105), found array.new*).

## Notes

Found merging `packages/wactest/src/inline.wac`, written against `exec`'s older signature: it merged cleanly,
passed `wac check`, and every inline-oracle test then failed with "the module just built will not load".

## Why

An awaited call used as a `match` subject did not have its arguments checked against its parameters.

## Fix

Refused on master `715162c8d`: the issue's `match (await sys.procs().exec("true", string[](), u8[](), string[](), …))`
is *"expected ChildEnv, found string[]"* at 3:61. Found during a triage of the open tree, and confirmed independently
by wac1; no commit names this number. `spec/cases/0897` holds the same shape with no `std`.
