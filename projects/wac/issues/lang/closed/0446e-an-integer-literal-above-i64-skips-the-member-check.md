# 0446e — an integer literal above `i64`'s range skips the member check

- **Status:** closed 2026-11-10 (cloud) — refused as out of range; `spec/cases/0912`
- **Claimed by:** wac2
- **Reported by:** wac2 (cloud), found while triaging `0262c`
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** accepted program — `check` clean, `build` cannot emit, with no position

## Reproduction

```wac
export i32 f() { return 9223372036854775808.nofield; }
```

Expected: refused by the checker — *no such field*, at the member — as it is for every smaller literal.
Actual, on master `715162c8d`:

    $ wac check g.wac
    g.wac: 1 file(s), no diagnostics
    $ wac build g.wac -o out
    wacc: cannot emit g.wac — the exported function `f` is not in the module the emitter produced — member of an unknown type

## Notes

The boundary is exactly `i64`'s maximum. Measured with `return N.nofield;`:

| N | `wac check` |
|---|---|
| `5`, `2147483648`, `4294967296`, `9223372036854775807` | refused (*no such field*) |
| `9223372036854775808`, `18446744073709551615` | **no diagnostics** |
| `18446744073709551616` — 2^64, which fits no type at all | **no diagnostics** |

So a literal the checker cannot give an `i64` type to is left untyped, and a member access on an untyped receiver
passes silently rather than being refused. The same literal in a typed slot is checked — `i32 f() { return
18446744073709551615; }` is *literal out of range for its type*, and `u64 x = 18446744073709551615; x.nofield` is
refused — so it is the receiver position, where there is no slot to type the literal from, that walks past.
`5.len()` is refused (*no i64.len*), which says what an untyped literal receiver is meant to default to.

`packages/wacc/test/wac/declined_test.wac`'s u64-literal fixture (`issues/lang/0262c`) reaches the emitter through
exactly this hole, so fixing this retires that fixture as well — `0262c`'s repoint-or-retire decision should be taken
with this in view.

## Why

A literal's natural type is `i32`, else `i64`; one wider than both answered unknown in `naturalTypeOf`, and a member
access on an unknown receiver is silent.

## Fix

`wideLiteralReceiver`, asked by `checkMember` and by a method call's receiver, reports *literal out of range for its
type — a receiver gives it no type, and it is wider than i64*, at the literal: `9223372036854775808.nofield`,
`18446744073709551615.nofield` and `18446744073709551616.len()` are all refused. A `u64` receiver is spelled with a
cast, `(18446744073709551615 as u64).m()`. `spec/cases/0912`. `0262c`'s fixture reaches the emitter through this same
hole, so its repoint-or-retire decision now has one answer fewer to weigh.
