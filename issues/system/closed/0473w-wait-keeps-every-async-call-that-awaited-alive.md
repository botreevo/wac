# 0473w — `wait()` on an async call that awaited another keeps the call, and all it holds, alive for good

- **Status:** closed 2026-11-13 (wac1) — `Host.enqueue` in `std/platform.wac`; `packages/platform/test/wac/waitleak_test.wac`
- **Reported by:** agent-w (the cloud session building wacuum, `git.voltrevo.com/wac-eth.git`)
- **Date:** 2026-11-13
- **Kind:** bug
- **Symptom:** out of memory: 3000 calls each holding 1 MB exhaust the heap, though none is reachable

## Reproduction

```wac
import { Sys } from "std";
async u8[] leafy(i32 i) { return u8[].filled(16, 1); }
async u8[] inner(i32 i) {
  u8[] big = u8[].filled(1 << 20, 1);
  u8[] x = await leafy(i);
  return big;
}
export i32 main(Sys sys) {
  for (i32 i = 0; i < 3000; i++) { inner(i).wait(); }
  sys.log("done");
  return 0;
}
```

At `7f559349c` on the native V8 host: "Fatal JavaScript out of memory: Ineffective mark-compacts near heap
limit" at 1.4 GB, before `done`.

Expected: `done`, in a few MB — each `inner(i)`'s result is dropped, and nothing else refers to it.
Actual: every call's `big` is retained.

## Notes

The shape matters, which is why the reproduction has both functions:

| | peak RSS, 3000 calls of 1 MB |
| --- | --- |
| `inner` with no `await`, driven by `wait()` | 31 MB |
| `inner` awaiting another async function, driven by `wait()` (above) | out of memory |
| the same awaited from an `async main` instead of `wait()` | 110 MB |

So it is `wait()` driving a ticket whose machine parked on another ticket: something the drive registers —
the parked continuation, a `whenSettled` callback, the inner ticket's link back to the outer — is never
released. wacuum met it running its fixtures against a state store on an in-memory disk, where every call
is driven to the end with `wait()`; its runners now `await` from `async main`, which does not leak.

## Fixed (2026-11-13, wac1)

The thing the drive registered was the continuation itself. `__wacMachine.run` hands each suspension's continuation
to the schedule target in force, and std's default target was `h.queued.push`. `wait` then steps the machine itself,
past that copy, which goes stale (`current()` false) and does nothing when called — but only `__wacDrain` and
`__wacLeft` ever dropped stale copies, and a plain `main` driving with `wait` calls neither. So every suspension's
continuation stayed queued, and through its resumer the machine, its coroutine and `big`. An `async main` drains,
which is why it did not leak; `inner` without an `await` never suspends, so nothing was queued.

The target is `Host.enqueue` now: it pushes, and once the queue has grown by as many as were live after the last
clearing (at least 64) it drops the stale ones — constant cost per suspension, and current work stays queued.

Measured, peak RSS of `wac run` (the compile included, in its child):

| host | before | after, 1000 / 3000 / 6000 calls |
| --- | --- | --- |
| V8 (native) | out of memory at 1.4 GB | 294 / 292 / 298 MB |
| wasmtime | — | 193 / 194 / 193 MB |
| Node | — | 551 / — / 556 MB |

Flat in the number of calls on every host. `packages/platform/test/wac/waitleak_test.wac` runs the reproduction on the
native host and requires `done`.
