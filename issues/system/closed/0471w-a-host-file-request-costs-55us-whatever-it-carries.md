# 0471w — A host file request costs ~55 µs whatever it carries, and requests in flight are served one at a time

- **Status:** closed 2026-11-13 (wac1) — the native hosts' `read_at_cached` and `on_file_pool` (`native/v8/src/main.rs`, `native/src/main.rs`); the vectored read is a separate std addition, awaiting its spec note
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

## Fixed (2026-11-13, wac1) — the cheaper request

**Where the 55 µs went: a thread spawned per request.** Both native hosts served `readAt` (and `writeAt`, `size`,
`truncate`, `sync`) by `try_clone`-ing the file and `std::thread::spawn`-ing a thread to do the call and complete the
ticket. Measured on the same 4-vCPU VM: a Rust `spawn` + `join` 55 µs, `dup` 0.3 µs, a 4 KB `pread` from the page
cache 0.5 µs, and a request the host answers inline (`nowMillis`) 4.3 µs on V8. The spawns were paid one after another
on the program's thread, which is why 64 in flight did not overlap. (A standing worker would still have cost ~25 µs a
hop here: cross-thread wake-ups are slow on this VM.)

**Now:** a `readAt` first tries `preadv2(…, RWF_NOWAIT)`, which reads only what the page cache already holds and
refuses with `EAGAIN` rather than wait for the disk, and is answered at once when it can be. Otherwise — not cached, or
a filesystem that cannot say — and for the other four operations, the call runs on eight standing threads started on
first use, not a thread per request. Measured with the reproduction's shape (`readAt` per request):

| host | 16 B before → after | 4 KB before → after | 4 KB, 64 in flight |
| --- | --- | --- | --- |
| V8 (native) | 57–66 µs → 5.5 µs | 67 µs → 7.6 µs | 68 µs → 7.5 µs |
| wasmtime | 74 µs → 10 µs | 147 µs → 48 µs | 77 µs → 18 µs |

On V8 a cached read now costs about the host round trip itself. wasmtime's 4 KB figure is mostly handing the bytes to
the program, not the read. With the file evicted (`posix_fadvise(DONTNEED)`), `strace` shows every `RWF_NOWAIT` read
refused and answered by the pool's `pread64`, with the same bytes; `packages/platform/test/wac/randomfile_test.wac`
asks both paths the same questions, evicting with `dd iflag=nocache`.

**Not here:**
- **The vectored read** (`readAtMany`) is a std API addition, so it waits on its spec note and approval; with the
  request this cheap it would save the remaining ~5 µs a key.
- **The Node host** is a different cost: a bare `nowMillis` round trip is 68 µs there and `readAt` 122 µs (43 µs with
  64 in flight), so its overhead is in the request bridge itself, not in file I/O.
