# 0018 — default arguments

- **Status:** proposed
- **Raised by:** cloud session, 2026-11-08, on the operator's decision to reopen default arguments after wac-sqlite
  and wac-tensor asked for them (`sum([], false)`, reduction APIs whose last flags are nearly always the same)
- **Not in scope:** positional constructors leaving out defaulted fields — the operator kept those strict
  (2026-11-08); named construction is how a struct's defaults are used, and this note does not change that

## The target

A function's or method's **trailing** parameters may have a default, and a call may leave them out:

```wac
f32[] sum(f32[] xs, i32[] axes = i32[](), bool keepDims = false) { … }

sum(xs);                     // axes = i32[](), keepDims = false
sum(xs, [0]);                // keepDims = false
sum(xs, [0], true);
```

What it is **not**: named arguments at a call (`sum(xs, keepDims: true)`), overloading, or a default that reads
another parameter. Each of those is a separate question, and the first is the one most likely to follow; this note
leaves room for it (below) and decides nothing about it.

## The rules

1. **Only trailing parameters.** Once one parameter has a default, every parameter after it has one. A call gives
   the parameters in order and stops; there is no skipping.
2. **A default is evaluated at each call that leaves it out, in the callee's file**, as a field's initialiser is at
   each construction that leaves it out (spec ch12 `§wac-field-initialiser-each-8upxvn7`) — so `i32[] seen = []` is a
   fresh array per call, and names in it resolve where the function was written, not where it is called (the bug
   `issues/lang/0435d` fixed for fields is the one to avoid from the start).
3. **A default is a constant expression or a construction** — literals, `static`s, operators over them, `T()`,
   `T[]()`, `[…]`, a variant. Not a call to an arbitrary function, and not a read of an earlier parameter. This keeps
   rule 2's "where it was written" cheap to honour: nothing in a default depends on the caller's frame, and nothing
   runs that could fail.
4. **The function's type is its full parameter list.** `sum` as a value is a `fn<f32[](f32[], i32[], bool)>`; a
   funcref call gives every argument. Defaults belong to the declaration, not to the type — two functions of one
   type with different defaults are interchangeable as values.
5. **An override keeps its parent's defaults**, and may not declare different ones: a call through the parent's
   type must mean the same thing whichever override runs.
6. **Exports carry their defaults.** A caller in another file or package sees them; bindgen's generated JavaScript
   mirrors them as JavaScript defaults, which have the same trailing-only shape.

## How it lowers

At the call site, before the checker's argument checks: a call with fewer arguments than parameters, where every
missing one has a default, is the call with each default appended — compiled in the callee's file, as
`emitFieldDefault` compiles an initialiser since 0435d. The checker then checks the full call as it does today, and
the emitter never sees a short call. The parser stores the default as the `Param`'s `init`, beside its type.

Nothing in the emitter changes but that append: wasm functions keep their full arity, so a module compiled against a
library without defaults links against one with them.

## Spec

Chapter 20 (functions) gains a section: the declaration rule (1, 3), the call rule (2), the type rule (4), and the
override rule (5), each with a case. The refusals: a default before a parameter without one; a default that is not a
constant expression or construction; an override with different defaults; a call with too few arguments for the
parameters without defaults — that last one the existing arity error, reworded to say how many are required.

## Steps

1. Parser: `Param.init`; the trailing rule. Spec text and the refusal cases.
2. Checker: arity counts parameters without defaults as the minimum; rule 3 and rule 5.
3. Lowering: the append at call sites (functions, methods, statics), in the callee's file.
4. bindgen: JavaScript defaults.
5. Use it where the projects asked: wac-tensor's reductions; nothing in this repository needs changing.

## Open

- Named arguments at a call would make "skip the middle one" possible. If they come, they come as their own note,
  and rule 1 stays: a named argument fills a parameter, a default fills one nobody named.
