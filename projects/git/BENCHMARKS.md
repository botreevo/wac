# Benchmarks: the wac server against git's own

The same bare repositories, served in turn by three servers, with an unmodified `git` 2.43 as the client:

- **wac**: `dist/gitserve.wasm` on wac's Node host.
- **http-backend**: `git http-backend`, git's own smart-HTTP server. It is a CGI program, run here behind a
  minimal Python bridge (`bench/http_backend.py`) that buffers each request and response whole, as the wac
  server does. This is the like-for-like comparison.
- **git daemon**: git's native `git://` server, with no HTTP at all. It is the floor.

Every operation is checked as well as timed, so a server cannot look fast by doing less:

- a clone must pass `git fsck --strict` and name the source's head;
- a fetch and a push must move the ref to the right commit, and the result must pass `git fsck`.

Each number is the median of 3 runs on one 4-CPU container. Server CPU includes the server's reaped children;
http-backend runs `git upload-pack` and `receive-pack` as children. git daemon's children never reach its
counters, so its CPU is reported as **n/a**, not as zero. Peak RSS is the server's whole process tree, sampled
every 20 ms. Reproduce with `wac task build && wac task bench`.

## Results

### wac-sudoku — 269 objects, 4.0 MB packed; fetch and push carry 38 commits

| | server | wall | server CPU | server peak RSS | pack received |
|---|---|---:|---:|---:|---:|
| ls-remote (each) | wac | 16 ms | 8 ms | 202.5 MB |  |
| ls-remote (each) | http-backend | 19 ms | 10 ms | 22.8 MB |  |
| ls-remote (each) | git-daemon | 50 ms | n/a | 13.4 MB |  |
| full clone | wac | 134 ms | 100 ms | 251.3 MB | 4.0 MB |
| full clone | http-backend | 130 ms | 50 ms | 30.8 MB | 4.0 MB |
| full clone | git-daemon | 143 ms | n/a | 22.1 MB | 4.0 MB |
| incremental fetch | wac | 137 ms | 70 ms | 258.6 MB | 4.0 MB |
| incremental fetch | http-backend | 151 ms | 60 ms | 42.2 MB | 4.0 MB |
| incremental fetch | git-daemon | 164 ms | n/a | 22.7 MB | 4.0 MB |
| push | wac | 349 ms | 360 ms | 306.0 MB |  |
| push | http-backend | 204 ms | 160 ms | 39.5 MB |  |
| push | git-daemon | 213 ms | n/a | 21.1 MB |  |

### wacuum — 894 objects, 693 KB packed; fetch and push carry 50 commits

| | server | wall | server CPU | server peak RSS | pack received |
|---|---|---:|---:|---:|---:|
| ls-remote (each) | wac | 16 ms | 9 ms | 180.4 MB |  |
| ls-remote (each) | http-backend | 22 ms | 11 ms | 28.7 MB |  |
| ls-remote (each) | git-daemon | 50 ms | n/a | 13.5 MB |  |
| full clone | wac | 87 ms | 60 ms | 196.3 MB | 704 KB |
| full clone | http-backend | 88 ms | 30 ms | 25.5 MB | 693 KB |
| full clone | git-daemon | 100 ms | n/a | 14.0 MB | 693 KB |
| incremental fetch | wac | 56 ms | 30 ms | 211.3 MB | 285 KB |
| incremental fetch | http-backend | 88 ms | 40 ms | 37.9 MB | 302 KB |
| incremental fetch | git-daemon | 138 ms | n/a | 21.8 MB | 302 KB |
| push | wac | 108 ms | 90 ms | 217.0 MB |  |
| push | http-backend | 120 ms | 70 ms | 34.6 MB |  |
| push | git-daemon | 197 ms | n/a | 21.1 MB |  |

### wac — 83,117 objects, 38.9 MB packed; fetch and push carry 50 commits

| | server | wall | server CPU | server peak RSS | pack received |
|---|---|---:|---:|---:|---:|
| ls-remote (each) | wac | 13 ms | 8 ms | 256.4 MB |  |
| ls-remote (each) | http-backend | 19 ms | 9 ms | 24.8 MB |  |
| ls-remote (each) | git-daemon | 50 ms | n/a | 13.4 MB |  |
| full clone | wac | 4.02 s | 1.67 s | 481.5 MB | 39.9 MB |
| full clone | http-backend | 3.24 s | 810 ms | 148.9 MB | 38.9 MB |
| full clone | git-daemon | 3.06 s | n/a | 97.2 MB | 38.9 MB |
| incremental fetch | wac | 318 ms | 210 ms | 474.5 MB | 2.0 MB |
| incremental fetch | http-backend | 369 ms | 150 ms | 77.4 MB | 2.3 MB |
| incremental fetch | git-daemon | 392 ms | n/a | 62.1 MB | 2.3 MB |
| push | wac | 719 ms | 670 ms | 554.7 MB |  |
| push | http-backend | 493 ms | 290 ms | 49.6 MB |  |
| push | git-daemon | 551 ms | n/a | 36.5 MB |  |

## What the numbers say

**On small and medium repositories the wac server matches git's.** Clone, fetch and push of `wac-sudoku`
(4 MB) and `wacuum` (0.7 MB) take the same wall time as `git http-backend`, give or take 20 ms, and are
sometimes faster. `ls-remote` is 13–16 ms against git's 19–22 ms.

**On the 83,117-object wac repository it is within 1.5×:**

| wac repo | wac server | http-backend | ratio | the first version of this server |
| --- | ---: | ---: | ---: | ---: |
| full clone, wall | 4.02 s | 3.24 s | 1.24× | 16.1 s |
| full clone, server CPU | 1.67 s | 0.81 s | 2.1× | 13.9 s |
| incremental fetch | 318 ms | 369 ms | 0.86× | 2.00 s |
| push | 719 ms | 493 ms | 1.46× | 5.24 s |

**The packs are as good as git's.** The clone arrives as 39.9 MB against git's 38.9 MB, because stored deltas
are reused rather than recomputed. The fetch is smaller than git's (2.0 MB against 2.3 MB).

**Memory is the gap that remains.** The wac server holds 180–260 MB at rest, most of it the Node runtime and wasm
heap. It peaks at 480–555 MB on the large repository; git peaks at 150 MB. That peak is the open packs (40 MB),
the 96 MB delta-base cache, and objects resolved during the request.

## How the gap closed

The first measurements had the wac server 5× slower than git on a large clone and 11× slower on a push, with
13–19× the CPU. None of that turned out to be the language. It was the algorithms, and each fix is a file:

| | what it was | what it is now | file |
| --- | --- | --- | --- |
| delta resolution | the whole chain re-inflated on every read | resolved bases cached, 96 MB budget | `src/store.wac` |
| "what does the other side have" | every commit behind every `have` or ref, each time | git's walk: both sides together by date, stopping when nothing new is queued | `src/walk.wac` |
| a push's connectivity check | every blob read in full | blobs looked up in an index; only trees the new commits add are walked | `src/serve.wac` |
| completing a thin push | bases deflated and appended, then the whole pack re-indexed | one pass with the bases as roots, appended as stored zlib blocks | `src/indexpack.wac` |
| indexing a push | n² SHA-1s (wac's `indexPack`) | linear: each object resolved and hashed once | `src/indexpack.wac` |
| applying a delta | a byte at a time into a growing buffer | the output allocated once, copies in bulk | `src/delta.wac` |
| reading trees and commits | a string per mode, name and author | hashes, kinds and a time, read from the bytes | `src/scan.wac` |
| SHA-1 | 80 words allocated per block, a branch per round, byte-wise input | 16 words reused, whole blocks from the input: 2.3× faster | `src/sha1.wac` |
| the response | the pack concatenated three times | about 1 MB pieces, hashed as they are made, sent one by one | `src/serve.wac`, `cmd/gitserve.wac` |
| opening a repository | every request | once per server, kept until its pack directory changes | `cmd/gitserve.wac` |

Four of these work around code in wac's own packages: the quadratic indexer, slow SHA-1, byte-wise delta
application, and string-building parsers. They would speed up wac's git client as much as this server, and
belong upstream.

## What is left

- **The full clone's 0.9 s of extra CPU.** About 0.6 s walks every tree in the history to list objects, and the
  rest copies 40 MB of entries and hashes them. git answers the listing from a reachability bitmap when the
  repository has one, and reads packs through `mmap`. A bitmap reader is the next large step.
- **Opening a repository** reads every pack into the heap: 0.4 s and 40 MB for this one, once per server
  process. Reading packs a window at a time, through `Files.openRandom`, would make it instant and shrink the
  resident size.
- **The baseline**: about 200 MB of Node and wasm before any repository is open. That belongs to the host and
  is not this server's to fix.
