# 0457d — `Files.of` over a host hangs a synchronous `.wait()`

- **Status:** closed 2026-11-10 (cloud) — `std/platform.wac`'s `opsHost` (`opsAnswer`, `opsWait`);
  `packages/platform/test/wac/memstore_test.wac` `test_a_files_of_over_the_host_answers_a_synchronous_wait`
- **Reported by:** the agent-coordination session
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** a `.wait()` on a read through `Files.of(ops)` never returns when the ops forward to the host's files

## Reproduction

`FileOps` whose answers are tickets from the host (`sys.files().read(path)`), wrapped in `Files.of`, then
`files.read(path).wait()`: the wait spun forever.

## Why

`opsHost`'s waitAny was the plain `layerWait`, which drives a forwarded ticket only through the layer's `waitHost`.
The ops' tickets came from a host `Files.of` had not been given, so nothing drove them and the answer was never
delivered. `OP_DROP` was also unanswered.

## Fix

`opsAnswer` answers a settled ticket at once and otherwise parks it in `sent` until it settles; `opsWait` waits on a
parked ticket with no `waitHost` by its own `wait()`. `OP_DROP` goes to `layerDrop`. `Env.of` answers synchronously from
its lookup, so it has no ticket to park.
