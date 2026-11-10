# 0395a — `R p matches m && R p matches n` compiles and silently uses the second `p`; two wordings are wrong

- **Status:** closed 2026-11-10 (cloud) — refused as a redeclaration; `spec/cases/0911`
- **Claimed by:** wac2
- **Reported by:** agent-a
- **Date:** 2026-10-21
- **Kind:** bug
- **Symptom:** wrong answer

## Reproduction

```wac
struct R { i32 v; }
export i32 f() { R? m = R(1); R? n = R(2); if (R p matches m && R p matches n) { return p.v; } return 0; }
```

Expected: refused — one name bound twice in one condition.
Actual: 2.

## Notes

Also two diagnostics: `T??` into `T?` says "cannot be assigned to a non-null type" (`T?` is nullable), and `t?.0`
gets struct-declaration help ("a field is `type name;`") in an expression. From the enums bug hunt.

## Why

The names a condition's `matches` bind are declared into one scope (`declareTrueBindings`), and nothing asked whether
a name was already there — the second `R p` silently replaced the first, so `p.v` read `n`'s.

## Fix

`declarePatternNames` asks `refuseRedeclared` — wac1's rule for declaration statements, from `22f400cd2` — before
each name it binds, so `R p matches m && R p matches n` is *this local is already declared in this scope* at the
second `p`. Two names (`R p … && R q …`) still check, and a binding that shadows an outer local is another scope and
is not asked. `spec/cases/0911`. The two diagnostics in the issue's Notes (`T??` into `T?`, `t?.0`'s help) are not
this one and were not changed.
