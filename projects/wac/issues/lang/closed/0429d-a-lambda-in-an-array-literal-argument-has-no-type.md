# 0429d — a lambda in an array literal handed to a call has no type

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `holdsLambda`; `spec/cases/0865`
- **Reported by:** cloud session, met while testing 0426d
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
struct T { i32 v; }
i32 many(fn<i32(T)>[] c) { return c[0](T(2)); }
export i32 f() { return many([(T t) => t.v * 10]); }
```

*cannot emit — a lambda (… 1 in a position the walk does not type yet …)*. Through a local
(`fn<i32(T)>[] l = [...]; many(l)`) it builds.

## Why

A call by name is a `Construct` to the parser, and the walk that gives lambdas their types resolves its
parameters only when an argument holds a lambda — `holdsLambda`, which looked into calls and constructions
but not into array or tuple literals or a ternary's branches. Answered no, the arguments were walked with no
wanted type.

## Fix

`holdsLambda` looks into array literals, tuple literals and both branches of a ternary.
