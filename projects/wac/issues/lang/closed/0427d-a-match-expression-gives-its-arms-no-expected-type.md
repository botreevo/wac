# 0427d — a `match` expression gives its arms no expected type, so a lambda arm has none

- **Status:** closed 2026-11-08 (cloud) — `check.wac`'s `MatchExpr` arm; `spec/cases/0866`
- **Reported by:** wac-tensor (`docs/wac-asks.md`)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** compile error

## Reproduction

```wac
enum Op { Neg, Id }
fn<f32(f32)> pick(Op op) { return match (op) { Neg: (f32 x) => 0.0 - x, Id: (f32 x) => x }; }
```

*nothing here wants a function, so this lambda has no type*. A ternary's branches take the expected type;
a `match`'s arms did not.

## Fix

Each arm's value is checked with the match's expected type, as a ternary's branches are. The emitter's walk
already handed the arms its wanted type.
