# 0446e — an integer literal above `i64`'s range skips the member check

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
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
