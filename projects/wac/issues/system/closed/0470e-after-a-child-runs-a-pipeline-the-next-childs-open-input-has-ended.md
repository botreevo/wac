# 0470e — after a spawned shell runs a pipeline, the next child this program spawns finds its open input ended

- **Status:** closed 2026-11-11 (wac2) — `native/v8/src/main.rs` `input_for_child`
- **Reported by:** wac2, porting box's `stdin_open.test.ts` to wac (`packages/box/test/wac/stdinopen_test.wac`)
- **Date:** 2026-11-11
- **Kind:** bug
- **Symptom:** wrong answer — a child reads the end of an input its parent is still holding open

## Reproduction

On the V8 host (`native/v8`), a test that spawns the built `packages/box/src/bin/sh.wac` as a module, twice:

1. `sh -c 'seq 1 3 | cat'`, its input a queue (`Launch.plain()`), waited for to its exit;
2. then `sh -c 'cat'`, its input a queue this program holds open and **never writes or closes**.

The second `cat` should wait for ever (the test bounds it with `Clock.within(child.exit(), 1500)` and expects
`TimedOut`). It exits 0 at once with no output: its input has ended.

    plain: ENDED; read: ENDED; within20k: ENDED; read+within5k: ENDED; read+within20k: ENDED

(whether or not the first child's output is read while it runs, whatever bound its exit is waited with). With
`echo hi` as the first script — no pipeline — the second `cat` waits, as it should, in every variant. So it is a
pipeline's stages, which the shell spawns as children of its own, that do it. It is timing-dependent: the first
version of `stdinopen_test.wac`, which ran its canary last, passed in one run and failed in the next three.

## Where to look

A pipeline's first stage *inherits* the shell's input (wac-mono 0110), and on this host an inheriting child does not
read its parent's input: `Cap::ReadChunk` and the unbounded read in `native/v8/src/main.rs` take `if s.inherits { None }
else { s.child_input.clone() }` and fall through to `std::io::stdin()` — the *process's* input — so a grandchild that
inherits reads the test process's own standard input, not the shell's. That is wrong on its own, and whatever the
stages do with that input on their way out (an end, a close of `STDIN_HANDLE`) is the likely route to a sibling's
queue. Not chased further: found while porting, and filed so the port could keep its canary honest — it now runs
first, before any pipeline.

## Fixed — wac2, 2026-11-11

That was it. `input_for_child` decides, at both spawn sites, what an inheriting child reads: for a child of this
process's own program, the process's input as before; for a child of a *child* — a pipeline stage a spawned shell
starts — the queue that parent reads, and the stage is told it is reading a queue rather than inheriting. The
reproduction above (as a probe test, every variant) now waits as it should, and `packages/sh/test/wac`,
`stdinopen_test`, `routes_test`, `sealed_test`, `binspawn_test`, `spawn_test` and `ended_test` pass on it. The
JavaScript hosts' children are workers with a bridge each and were not affected.
