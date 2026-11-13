# 0473w — `wait()` on an async call that awaited another keeps the call, and all it holds, alive for good

- **Status:** open
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
