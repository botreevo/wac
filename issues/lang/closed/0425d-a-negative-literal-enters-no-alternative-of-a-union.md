# 0425d — a negative literal handed to a union enters no alternative, and the refusal names no place

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `unionTargetE` (`isSignedNumericLiteralE`); `spec/cases/0863`
- **Reported by:** wac-tensor (`docs/wac-asks.md`)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
struct T { i32 f(this, union<T, f64> x) { return 0; } }
export string test_n() { T t = T(); t.f(-0.5); return ""; }
```

`wac check` is clean; the build answers *cannot emit — a value that enters no alternative of union<T, f64>*,
with no position. `0.5` and `0.0 - 0.5` build.

## Why

`unionTargetE` sent a numeric literal to the union's one numeric alternative, but asked only whether the
expression *was* an `IntLit` or `FloatLit`. `-0.5` is a unary minus over one, so it fell through to the
type-based search, and a literal's type answers no alternative. The decline then said what but not where,
which cost the reporter half an hour of bisecting a 950-line file.

## Fix

A negated literal is a literal there (`isSignedNumericLiteralE`), and the decline names the line and column.
The "a lambda … the walk does not type yet" decline names the lambda's position too.
