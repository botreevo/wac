# 0439d — a conditional returned as a nullable number is not boxed

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `Ternary` arm; `spec/cases/0874`
- **Reported by:** the autonag-in-wac session
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
i64? g(i64 v, i64 w) { return v < w ? v : w; }
```

Builds; the engine refuses it — *type error in return[0] (expected (ref null N), got i64)*. `return v;` in the same
function is boxed.

## Why

A conditional going into a box boxes at its arms (`boxesAtBranches`), but its block took the arms' own type, `i64`,
so each arm was emitted unboxed into a block that then stood where an `i64?` was due.

## Fix

Into a boxed slot, the block's type is the slot's, and each arm, emitted at it, boxes itself.
