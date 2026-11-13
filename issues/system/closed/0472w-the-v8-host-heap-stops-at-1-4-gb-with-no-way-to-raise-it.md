# 0472w — The V8 host's heap stops at ~1.4 GB, with no way to raise it

- **Status:** closed 2026-11-13 (wac1) — `native/v8/src/main.rs` (`heap_max_bytes`, `near_heap_limit`, `out_of_heap`, `--max-heap`); `packages/platform/test/wac/heaplimit_test.wac`
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

## Fixed (2026-11-13, wac1)

**What the limit was.** V8's managed heap, not wasm linear memory: a wac value is a WasmGC object, and both places the
native host made an isolate used `v8::Isolate::new(Default::default())` with no flags, so V8's default old-space
ceiling applied — about 1.4 GB. **It is an isolate setting**, `CreateParams::heap_limits(initial, max)` (what
`--max-old-space-size` sets in Node). This build has pointer compression off — the `v8` crate's
`v8_enable_pointer_compression` feature is not enabled — so the 4 GB cage of a compressed heap does not apply: on a
16 GB machine 10 GB was held under `--max-heap 11g`.

**What it is now.**

- **Default: half of physical memory** (`sysconf`), so 8 GB on a 16 GB machine; 7 GB held with no flag.
- **`WAC_MAX_HEAP=<size>`** — `8g`, `512m`, `64k`, `1t` or bytes — read by every isolate the process makes.
- **`wac --max-heap <size> <command> …`**, first on the line: the binary sets `WAC_MAX_HEAP` and runs itself again
  without it, so the command, the program it runs (an isolate on another thread) and any child process all have it. A
  size that is not one is refused with status 2. A host without the setting says so and ignores it.
- **Running out is a sentence, not an abort.** A near-heap-limit callback stops the program and grants headroom once
  (a sixteenth plus 64 MB); the run ends `HostLimit` with *"wac: x.wac ran out of memory: its heap reached the limit of
  N MB — raise it with `wac --max-heap <size>` or WAC_MAX_HEAP (like 8g)"*, status 255 as a host limit reports. A loop
  that allocates without calling the host is not stopped by the termination, and then V8 ends the process — after
  printing its GC trace — with the same sentence from the OOM handler, still at the limit plus the one grant (a program
  told 8 GB peaked at 8.6).

**Other hosts.** The wasmtime host keeps its own GC heap sizing and Node its `--max-old-space-size` (through
`NODE_OPTIONS`); neither reads `WAC_MAX_HEAP` yet.
