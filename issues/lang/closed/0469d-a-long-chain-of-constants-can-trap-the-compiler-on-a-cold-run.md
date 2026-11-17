# 0469d — a long chain of constants can trap the compiler on a cold run, and not on a warm one

- **Status:** closed 2026-11-17 (cloud) — `packages/wacc/src/consteval.wac` (`demandConst`, `demandOneConst`, `deferredCycle`); `packages/wacc/test/wac/constchain_test.wac`
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

## Fix

**It was a stack overflow, and deterministic.** A constant reading another is a recursion of the static evaluator
(`demandConst` → `evalExpr` → `demandConst`). Asked of the real compiler on 2026-11-14: 2000 statics each reading the
one before, declared from `C0` up, checked clean and failed `wac build` with "Maximum call stack size exceeded";
declared from the top down, so the first constant the checker asks for reads every other one, `wac check` failed too.
600 ran. The cold/warm difference in the report was the depth sitting near the limit, where frame sizes decide it.

**An ask more than `constDeferDepth()` (128) constants deep defers to the outermost ask.** Everything between unwinds,
unsettled, with a status nothing outside the evaluator sees (`evDeferred`); the outermost ask computes the constant
that was wanted, then asks again. The values and the dependency order (`constOrder`) are the ones the recursion gave,
and the stack never holds more than the bound. A chain that comes back to an ask still waiting is a cycle: the stacks
the deferrals saw, end to end, are the stack the unbounded evaluator would have had, so the message names the same
constant and the same chain, now not cut at the demand stack's 256 entries, and every constant on it gives up with those
words. `constchain_test.wac`: chains of 3001 in both orders build and run, and a 300-long cycle is said in full. The
first two trapped on the old compiler.
