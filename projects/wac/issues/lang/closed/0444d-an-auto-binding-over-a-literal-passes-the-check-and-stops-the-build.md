# 0444d — an `auto` binding over a literal passes the check and stops the build

- **Status:** closed 2026-11-10 (cloud) — `check.wac`'s `untypedAtAuto`, `emit.wac`'s `mixedBindingTypeE`;
  `spec/cases/0879`, `spec/cases/0880`
- **Reported by:** cloud session, writing the case for 0443d
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
export i32 f() { (i32 a, auto b) = (1, 2); return a + b; }     // b has no type to take
export i32 g() { i32 x = 2; (i32 a, auto b) = (1, x); return a + b; }   // well typed
```

Both pass `wac check`; both builds say *a destructuring declaration of a value whose tuple type is unknown*.

## Why

Two halves of one gap. `auto x = 3;` is refused — a literal gives `auto` nothing — but an `auto` binding in a pattern
was not asked the same question, so `f` passed. And in `g`, every binding has a type (`i32` written, `x`'s taken), but
the emitter typed the pattern either from all its written types or from the whole initialiser, and `(1, x)` as a whole
has none for its `1`.

## Fix

The checker refuses a literal number landing on a binding with no written type, as it does for an `auto` local. The
emitter types a partly typed pattern over a tuple written out position by position: the written type where there is
one, the member's own where not.
