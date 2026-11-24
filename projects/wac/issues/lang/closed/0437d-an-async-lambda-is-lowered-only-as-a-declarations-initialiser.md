# 0437d — an `async` lambda is lowered only as a declaration's initialiser

- **Status:** closed 2026-11-08 (cloud) — `asynclower.wac`'s `hoistAsyncLambdas` and the slot lines of `ticketSigsOf`; `spec/cases/0872`
- **Reported by:** wac-kps (`Driver.openChannel`, a `fn<Ticket<Channel?>(WebrtcStream)>` every implementation filled by hand)
- **Date:** 2026-11-08
- **Kind:** missing feature
- **Symptom:** emit failure

## Reproduction

```wac
import { Ticket } from "core";
Ticket<i32> ready(i32 v) { Ticket<i32> t; t.resolve(v); return t; }
struct Driver { fn<Ticket<i32>(i32)> open; }
export i32 f() { Driver d = Driver(async (i32 n) => { i32 v = await ready(n); return v * 2; }); return d.open(21).wait()!; }
```

`wac check` is clean — spec ch35 `§wac-async-lambda-slot-9wq4nkz` allows an `async` lambda wherever the expected type
is a `fn<Ticket<R>(…)>` — and the build refused *an `async` lambda the lowering did not take*. The same for one handed
to a parameter, written as a named field's value, assigned to a field, or returned. Only
`fn<Ticket<i32>(i32)> g = async …;` built.

## Why

The lowering runs on the tree with no types, and the machine needs the lambda's `R` to declare the cell its answer
lands in. A lambda writes no return type, so `R` was read from the one place it is written beside the lambda: a
declaration's type.

## Fix

`R` is read from the slot the lambda fills, as written in whichever file declares it: `ticketSigsOf` records every
parameter and field of a `fn<Ticket<R>(…)>` type — `@p:f#i`, `@p:Owner.m#i`, `@f:Owner.field`, `@c:Owner#i` — beside
the ticket-answering functions it already recorded, and a `return` reads the enclosing function's return type.
`hoistAsyncLambdas` moves each such lambda into the form the lowering takes, `fn<Ticket<R>(P…)> __wacAwK = async …;`,
just before its statement, and leaves the name where it was. Making a lambda runs nothing and it captures by reference,
so made a statement earlier it is the same lambda. A method's parameter and an assigned field are found by name, since
the pass does not know a receiver's type; where two declarations of that name disagree, the lambda is left and refused
as before.
