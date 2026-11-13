# 0469d — a long chain of constants can trap the compiler on a cold run, and not on a warm one

- **Status:** open
- **Claimed by:** wac1 (after the silent-cap sweep's second batch)
- **Reported by:** wac1, writing `packages/wacc/test/wac/manystatics_test.wac` for the sweep after `issues/lang/0468d`
- **Date:** 2026-11-13
- **Kind:** bug (compiler robustness)
- **Symptom:** the compiler traps — nondeterministically — on a program of 511 or 600 chained statics

## Reproduction

A program of N constants, each the one before plus one, compiled in a wac test through
`artifacts_probe.wac`'s `runEmittedOne` (the compiler running in the test's own instance):

```wac
static i32 C0 = 1;
static i32 C1 = C0 + 1;
// … up to
static i32 C599 = C598 + 1;
export i32 main() { return C599 % 250; }
```

At 600, the first run of a freshly written test file reported `trapped`; the next two runs of the same file passed.
At 511 one run trapped and a later one passed; at 1100 both runs passed. With independent constants
(`static i32 Ck = k + 1;`) every count up to 1100 passes every time — which is how the test is written now.

## Notes

Not yet diagnosed. What fits: `demandConst` (`packages/wacc/src/consteval.wac`) evaluates a constant by demanding the
ones it reads, so a chain of 600 recurses 600 deep — several wasm frames per level. A cold run executes the compiler's
baseline (Liftoff) code, whose frames are larger than the optimised code a warm, cached run gets, so the same depth
can overflow the stack only on a cold run. That would also explain why 1100 passed (run warm, after the others).

What to find out: whether the trap is a stack overflow and at what depth; whether `wac build` (the compiler in its own
child, with the host's stack) hits it too; and whether `demandConst` should be iterative — a worklist over the
dependency order, which `constOrder` already records — so a chain's length never meets the stack at all.
