# 0449e — `wait()` on an `async` call has no type in a file that does not import `Ticket`

- **Status:** closed 2026-11-10 (cloud) — `packages/wacc/src/api.wac`'s reach declares core's `Ticket` for an entry that writes `async`; `spec/cases/0904`
- **Reported by:** wac2 (cloud), found while fixing `0399b`
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** accepted program — `check` clean, the module invalid

## Reproduction

```wac
async i32 one() { return 1; }
export i32 f() { i32 x = one().wait(); return x; }
```

Expected: refused — *expected i32, found Result<i32, Stuck>*, as it is once the file imports anything from `std`.
Actual, on master `715162c8d`: `wac check` says *no diagnostics*, and `wac compile` says *the compiler produced a
module the engine will not load*.

## Notes

With `import { Sys } from "std";` (or `import { Ticket } from "core";`) added, the same line is refused with the
expected message, so the checker can type `wait()` and does not in a file that reached `Ticket` only through an
`async` function's result. Any rule that asks the type of `one().wait()` is silent there — `0399b`'s cast refusal
included: `one().wait() as! i32` checks clean without the import. Same family as `0436d` (a `core` type `std` hands
on had no members), one route over.

## Fix

The reach over imported signatures declared what the entry imports and what those signatures hand on, but an entry's own `async` function answers core's `Ticket` without naming it, and nothing reached it. It is declared now — not nameable, as a name `std` hands on is — for an entry that writes `async`, and not where the entry declares a core name itself (the spelling clash `issues/lang/0436d` describes).
