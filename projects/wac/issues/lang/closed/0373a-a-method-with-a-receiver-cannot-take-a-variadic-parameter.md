# 0373a — A method with a receiver cannot take a variadic parameter

- **Status:** closed 2026-11-10 (cloud) — `lowerVariadics` packs a receiver method by name; `spec/cases/0903`
- **Claimed by:** wac2
- **Reported by:** agent-a
- **Date:** 2026-10-14
- **Kind:** missing feature
- **Symptom:** compile error

## Reproduction

```wac
struct Box<T> {
  T v;
  i32 plus<Ts>(this, Ts ...xs) { return typeref(Ts).tupleMembers().len(); }
}

export i32 f() { Box<i32> b = Box(1); return b.plus("x", true); }
```

Expected: `f() = 2` — ch14 `§wac-variadic-tuple-sfevn82` is about "a parameter", not a function's.
Actual: *a method with its own type parameters cannot be called yet* — nothing packed the two arguments into
one tuple, so the method's `Ts` is matched against two arguments and binds nothing.

## Notes

Variadics are a source rewrite before parsing for real (`lowerVariadics` in `packages/wacc/src/api.wac`): a
call to a variadic name has its trailing arguments wrapped in a tuple. It works by name, so it can lower a
free function and, since 2026-10-14, a method with no receiver (`Box.count(…)`, `Box<i32>.count(…)` — keyed
`Owner.name`, which is the shape of core's `Ticket.all`). `x.plus(…)` cannot be lowered that way: which
`plus` it calls depends on `x`'s type, which text does not have. Packing has to move to a phase that knows the
receiver's type, or the call site has to be found some other way.

## Why

Variadics are packed by a text rewrite keyed by name, and `x.plus(…)` was skipped because which `plus` it calls
depends on `x`'s type.

## Fix

The type is not needed where nothing else shares the name: if every member called `plus` — across the program and
`core`'s and `std`'s carried text — is a variadic method with a receiver and one fixed-parameter count, every one of
them packs a call the same way. `lowerVariadics` gathers such methods as `.plus` and packs `x.plus(…)`,
`f().plus(…)` and the rest by name; `receiverVariadicClashes` drops a name that another receiver method of a
different shape, or a field (which may hold a function), also answers to, and such a call is refused as before.
The issue's `b.plus("x", true)` answers 2. `spec/cases/0903` holds a generic owner, an empty call and fixed
parameters before the pack.

Not changed, and not this issue: an untyped integer literal gives a variadic's `Ts` nothing to infer, so
`b.plus(3)` is *nothing here says what Ts is* — write `3 as i32`, as the spec's own `count(1 as i32, "a")` does.
That is true of a free function too.
