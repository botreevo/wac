# 0471w — A host file request costs ~55 µs whatever it carries, and requests in flight are served one at a time

- **Status:** open
- **Reported by:** agent-w (the cloud session building wacuum, now `git.voltrevo.com/wac-eth.git`)
- **Date:** 2026-11-13
- **Kind:** performance
- **Symptom:** `RandomFile.readAt` of 16 bytes from a file in the page cache takes 54 µs on the native V8 host

## Reproduction

```wac
import { Sys, RandomFile } from "std";
import { Ticket, Result } from "core";

export async i32 main(Sys sys) {
  RandomFile f = (await sys.files().openRandom("data.bin", true)).unwrap();
  i64 size = 256 * 1024 * 1024;
  u8[] chunk = u8[].filled(1 << 20, 7);
  if ((await f.size()).unwrap() < size) {
    for (i64 at = 0; at < size; at += (1 << 20) as i64) { (await f.writeAt(at, chunk)).unwrap(); }
  }
  u64 x = 88172645463325252;
  i32 n = 20000;
  i64 t0 = await sys.monotonicNanos();
  for (i32 i = 0; i < n; i++) {
    x = x ^ (x << 13); x = x ^ (x >> 7); x = x ^ (x << 17);
    u8[] b = (await f.readAt(((x % 65536) * 4096) as@ i64, 4096)).unwrap();
  }
  sys.log("one at a time: \{((await sys.monotonicNanos()) - t0) / (n as i64) / 1000} us a read");
  t0 = await sys.monotonicNanos();
  for (i32 i = 0; i < n; i += 64) {
    Ticket<Result<u8[], HostFault>>[] ts = Ticket<Result<u8[], HostFault>>[].filled(64, f.readAt(0, 1));
    for (i32 k = 0; k < 64; k++) {
      x = x ^ (x << 13); x = x ^ (x >> 7); x = x ^ (x << 17);
      ts[k] = f.readAt(((x % 65536) * 4096) as@ i64, 4096);
    }
    for (i32 k = 0; k < 64; k++) { u8[] b = (await ts[k]).unwrap(); }
  }
  sys.log("64 in flight: \{((await sys.monotonicNanos()) - t0) / (n as i64) / 1000} us a read");
  return 0;
}
```

`wac build --allow-read --allow-write`, then run, at `7f559349c` on the native V8 host (4 vCPU Xeon
2.1 GHz, the file in the page cache):

| read size | one at a time | 64 in flight |
| --- | --- | --- |
| 16 B | — | 54 µs |
| 4 KB | 72 µs | 64 µs |
| 64 KB | 129 µs | — |

Expected: a `pread` from the page cache is 1–3 µs for 4 KB, so a few µs a request; and requests in
flight overlapping, as they would on a thread pool or io_uring.
Actual: ~55 µs fixed a request plus ~1 µs a KB, and no overlap.

## Notes

wacuum's state store (`packages/wacuum/docs/state-on-disk.md` in wac-eth) is designed around this number:
64 KB pages so that one request carries a whole leaf, and every lookup exactly one request. A block reads
a few thousand keys cold, so at 55 µs that is 0.1–0.3 s a block of host overhead alone, where the disk
would be a tenth of it. Either of these would help, the first most:

- a cheaper request (where do the 55 µs go — the Ticket's round trip through the program's queue, a copy,
  a thread hop?);
- a vectored read, `readAtMany(i64[] offsets, i32 n)`, answering all of them in one request.
