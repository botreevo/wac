# 0436d — a type reached only through `std` has no members to the checker, and everything after it goes quiet

- **Status:** open
- **Reported by:** cloud session, met writing a test; the shape of wac-kps's "the checker accepts things that only fail at build"
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** accepted program (then an emit failure)

## Reproduction

```wac
import { Sys } from "std";
export string test_y(Sys sys) {
  string dir = "/tmp/x-\{(sys.clock().nowMillis().wait().ok() ?? 0 as i64)}";
  return dir == "" ? "bad" : "";
}
```

`wac check` is clean; the build answers *text from a Result<i64,Unsupported>, which has no `[toString]`*. `.ok()` on a
`Result<Result<i64, …>, Stuck>` is a `Result`, and `?? 0 as i64` beside it is a mismatch the checker refuses — in a file
that imports `Ticket` from `core`. In one that does not, `c.nowMillis().wait()` had no type at all.

## Why

`nowMillis` answers core's `Ticket<…>`, which this file never named; the checker knows a type's methods only where
it is declared or reached. The reach over imported signatures (`closeOverSignatures`, then each reached name followed
to the file that declares it) skipped `std` — "whose bodies are fixed when the compiler is built" — so a type `std`'s
signatures hand on from `core` was never declared here. `wait()` then had no member to find, the call answered
unknown, and every rule after it went quiet.

## Tried

Following `std` in the reach (dropping `|| paths[i] == "std"` from the skip in `checkFilesAutoIn`'s loop) makes the
CLI refuse the reproduction, and the repository's entries still check clean — but two suite tests disagreed:

- `test_cases_wacc_against_the_corpus` still accepted the case (`spec/cases/0871` then), so the corpus runner's check
  reaches `std` some other way;
- `test_rung_3_the_repositorys_own_code_checked_no_false_alarm` reported six false alarms in
  `packages/quic/test/wac/complete_test.wac` — *Result takes type arguments*, *expected Datagrams?, found T?* — so a
  type reached through `std` was declared where what it names (`core`'s `Result`) is not.

Reverted 2026-11-08. A fix has to declare a reached type together with what its signature names, or not at all.
