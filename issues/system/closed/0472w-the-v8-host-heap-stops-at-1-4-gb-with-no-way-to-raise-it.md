# 0472w — The V8 host's heap stops at ~1.4 GB, with no way to raise it

- **Status:** open
- **Reported by:** agent-w (the cloud session building wacuum, now `git.voltrevo.com/wac-eth.git`)
- **Date:** 2026-11-13
- **Kind:** missing feature
- **Symptom:** "Fatal JavaScript out of memory: Ineffective mark-compacts near heap limit" at 1384 MB, on a
  machine with 15 GB free

## Reproduction

```wac
import { Sys } from "std";
import { Map } from "core";

i32 h(i64 k) { return (k ^ (k >> 32)) as! i32; }
bool e(i64 a, i64 b) { return a == b; }

export i32 main(Sys sys) {
  Map<i64, u8[]> m = Map.create(h, e);
  for (i64 i = 0; i < 40000000; i++) { m.set(i, u8[].filled(64, 1)); }
  sys.log("\{m.len()}");
  return 0;
}
```

At `7f559349c` on the native V8 host this dies near 1.4 GB of heap. wacuum hit it holding a million
accounts in its `World` (`issues` in wac-eth: `packages/wacuum/docs/mainnet.md`, "Memory").

Expected: a way to give a program more heap — a host flag (`wac --heap 8g prog.wasm`), an environment
variable read by the host, or a grant — up to what the machine has; or a default sized to the machine.
Actual: V8's own default, and nothing in `native/v8/src` sets or forwards a heap limit.

## Notes

An Ethereum client caches state in memory: geth's default cache is 4 GB. wacuum's design keeps its
caches in ~1 GB to fit today's ceiling, which costs reads. With pointer compression a V8 heap is capped at
4 GB per isolate anyway, so the ask is that ceiling, not more.
