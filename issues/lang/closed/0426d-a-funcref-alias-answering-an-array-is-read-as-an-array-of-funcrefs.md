# 0426d — a `type` alias of a funcref answering an array is read as an array of funcrefs

- **Status:** closed 2026-11-08 (cloud) — `consteval.wac` `fnSuffixed`; `emit.wac` `emitterSpelling`; `spec/cases/0864`
- **Reported by:** wac-tensor (`docs/wac-asks.md`)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure (and, inside a larger module, a module the engine would not load)

## Reproduction

```wac
struct T { i32 v; }
type B = fn<T?[](T)>;
void take(B b) { }
export string test_a() { take((T t) => [t]); return ""; }
```

*cannot emit — a lambda (this module has 1, 1 in a position the walk does not type yet)*. With the parameter
written `fn<T?[](T)>` it builds.

## Why

The static evaluator spells a computed type the checker's way, and spelled `fn<T[](T)>` as `fn(T) -> T[]`
and `fn<T(T)>[]` as `fn(T) -> T` + `[]` — the same string. The emitter's `emitterSpelling` peeled the
trailing `[]` first, so the alias became `fn[T(T)][]`, an array, which no lambda can be.

## Fix

The evaluator brackets a funcref before a suffix, as the checker's `suffixed` does — `(fn(T) -> T)[]`,
`(fn() -> i32)?` — and the `typeref` operations read the brackets. `emitterSpelling` reads a bracketed
funcref with its suffix, and peels `[]` or `?` only from what is not a funcref.
