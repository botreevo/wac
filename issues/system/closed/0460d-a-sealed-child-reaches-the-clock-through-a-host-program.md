# 0460d — a sealed child reaches the clock through a host program

- **Status:** closed 2026-11-10 (cloud) — the `exec` handler of each host (`native/v8/src/main.rs`, `native/src/main.rs`,
  `packages/platform/host/node.ts`, `packages/platform/host/deno.ts`); `packages/platform/test/wac/sealed_test.wac`
- **Reported by:** wac1, while writing `Launch.sealed()`; raised again by the agent-coordination session for reckon
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** a sealed run that is not a function of what it was handed

## Reproduction

A child spawned with `Launch.plain().sealed()` and handed `sys.procs()` asks `procs.exec("/bin/date", …)`: it ran, on
every host, and its output is the time. Any host program has a clock and random bytes of its own, so `exec` handed back
what the seal took away — and reckon records sealed runs as deterministic.

## Why

The seal refused the four clock and random requests by opcode. `exec` is guarded by the `run` grant alone, and a sealed
child can hold `run`.

## Fix

Each host's `exec` asks first whether the program is sealed and answers `Unsupported` if it is, before the `run` grant.
The browser host has no `exec`. Spec ch44 `§wac-std-sealed-child-w4kq9ve` names `exec` among what a sealed program
cannot do; `sealed_probe.wac`'s child now tries it.
