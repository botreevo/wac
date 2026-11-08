# 0425w — a struct named `Host` makes every async test unemittable

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** cloud (wac-kps)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** compile error (emission declines; `wac check` is clean)

## Reproduction

```wac
struct Host { i32 x; }
export async string test_x() { await; return ""; }
```

`wac test --allow-read that_test.wac`:

```
wacc: cannot emit that_test.wac — a lambda (this module has 321, 12 in a position the walk does not type yet,
0 sharing a position key; the first at std:2488:5)
```

Expected: the test runs — a program's own `Host` and std's are two types (tour §16: two files may each declare a
name and stay distinct). Actual: the module is refused. The same file with the struct renamed passes, and so does
the same code built as a program whose `main` takes `Sys` rather than run as a test.

The struct need not be in the test file: one imported from a library two files away has the same effect, which is
how it was met — `wac-kps`'s WebRTC engine declared `struct Host` for the driver beneath it, and every async test
of the engine was refused.

## Notes

The twelve lambdas are std's, starting with `servedHost` in `std/platform.wac` (`Host.of((i32 op, …) => …, …)`).
A test adapter (`testEntry` in `packages/wacc/src/program.wac`) reaches std's host machinery, and the emitter's
lambda walk (`findLambdasExpr`, the `Call` / `Member` branch) resolves the receiver `Host` of `Host.of` as a bare
name — `env.isStructName(rn)` — so with a second `Host` in the program it finds the wrong one (or none), the static
is not found, and the lambdas passed to it have no target type.

0421c is the same collision met from the other side: the adapter imports std's `Host` and `Sys` under names of its
own (`@"$wacHost"`) so that a program's `Host` cannot clash with them. That protects the adapter's text; this is std's
own source, which spells the bare name and is resolved in the linked program.

The emitter's decline now names the first untyped lambda's file and position (`; the first at std:2488:5`), which is
what found this — the count alone sent the bisection to the wrong files.

**A second instance, the same class:** `packages/webrtc`'s `Session` holds a `Map<i32, Channel>` of a private
`struct Channel`, and a program that also declares a `Channel` (wac-kps's engine does) is refused at emission with
*"a call to `Map<i32,Channel>.create`, which this expression is emitted as and which is not in the program"* —
the instantiation is named by the bare struct name and finds the program's `Channel` rather than the session's.
`wac check` is clean. So it is not only `Host`, and not only lambdas: a generic instantiated at a type whose name
is declared twice in the program can resolve to the wrong one.

Workaround: name the struct something else (`wac-kps` calls its host `Driver`; the session's private struct is
`ChannelState`).
