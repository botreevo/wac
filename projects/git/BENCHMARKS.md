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
| ls-remote (each) | wac | 15 ms | 9 ms | 201.9 MB |  |
| ls-remote (each) | http-backend | 15 ms | 7 ms | 22.0 MB |  |
| ls-remote (each) | git-daemon | 49 ms | n/a | 13.3 MB |  |
| full clone | wac | 258 ms | 230 ms | 277.1 MB | 4.0 MB |
| full clone | http-backend | 135 ms | 40 ms | 32.7 MB | 4.0 MB |
| full clone | git-daemon | 132 ms | n/a | 21.9 MB | 4.0 MB |
| incremental fetch | wac | 257 ms | 170 ms | 311.1 MB | 4.0 MB |
| incremental fetch | http-backend | 144 ms | 50 ms | 34.5 MB | 4.0 MB |
| incremental fetch | git-daemon | 154 ms | n/a | 22.8 MB | 4.0 MB |
| push | wac | 648 ms | 660 ms | 323.5 MB |  |
| push | http-backend | 167 ms | 130 ms | 43.0 MB |  |
| push | git-daemon | 191 ms | n/a | 21.0 MB |  |

### wacuum — 894 objects, 693 KB packed; fetch and push carry 50 commits

| | server | wall | server CPU | server peak RSS | pack received |
|---|---|---:|---:|---:|---:|
| ls-remote (each) | wac | 18 ms | 9 ms | 180.2 MB |  |
| ls-remote (each) | http-backend | 21 ms | 11 ms | 24.7 MB |  |
| ls-remote (each) | git-daemon | 50 ms | n/a | 13.4 MB |  |
| full clone | wac | 238 ms | 240 ms | 195.2 MB | 704 KB |
| full clone | http-backend | 85 ms | 30 ms | 19.3 MB | 693 KB |
| full clone | git-daemon | 102 ms | n/a | 14.0 MB | 693 KB |
| incremental fetch | wac | 133 ms | 110 ms | 200.3 MB | 285 KB |
| incremental fetch | http-backend | 84 ms | 40 ms | 37.7 MB | 302 KB |
| incremental fetch | git-daemon | 140 ms | n/a | 22.2 MB | 302 KB |
| push | wac | 367 ms | 340 ms | 223.9 MB |  |
| push | http-backend | 126 ms | 80 ms | 34.8 MB |  |
| push | git-daemon | 195 ms | n/a | 21.1 MB |  |

### wac — 83,117 objects, 38.9 MB packed; fetch and push carry 50 commits

| | server | wall | server CPU | server peak RSS | pack received |
|---|---|---:|---:|---:|---:|
| ls-remote (each) | wac | 16 ms | 8 ms | 331.9 MB |  |
| ls-remote (each) | http-backend | 19 ms | 10 ms | 24.7 MB |  |
| ls-remote (each) | git-daemon | 50 ms | n/a | 13.6 MB |  |
| full clone | wac | 16.12 s | 13.90 s | 833.4 MB | 39.9 MB |
| full clone | http-backend | 3.27 s | 770 ms | 149.9 MB | 38.9 MB |
| full clone | git-daemon | 3.02 s | n/a | 97.7 MB | 38.9 MB |
| incremental fetch | wac | 2.00 s | 2.01 s | 420.6 MB | 2.0 MB |
| incremental fetch | http-backend | 379 ms | 150 ms | 77.4 MB | 2.3 MB |
| incremental fetch | git-daemon | 401 ms | n/a | 63.2 MB | 2.3 MB |
| push | wac | 5.24 s | 5.24 s | 574.1 MB |  |
| push | http-backend | 481 ms | 280 ms | 50.6 MB |  |
| push | git-daemon | 519 ms | n/a | 36.6 MB |  |


## What the numbers say

**Small requests are on par.** `ls-remote` takes 15–18 ms on wac and 15–21 ms on http-backend. That holds
only because open repositories are kept between requests. Before that change, every request re-read the
packs, and an `ls-remote` cost wac 45 ms of CPU on a 4 MB repository.

**The packs are as good as git's.** A full clone of wac's 83,117 objects arrives as 39.9 MB from this server
and 38.9 MB from git, because stored deltas are reused rather than recomputed. The 50-commit incremental fetch
is slightly smaller from wac (2.0 MB against 2.3 MB). The wac server sends exactly what the new commits reach
beyond their parents' trees.

**Bulk work is several times slower:**

| | full clone | incremental fetch | push |
| --- | ---: | ---: | ---: |
| small and medium repos, wall time vs http-backend | about 2–3× | about 1.5–2× | about 3–4× |
| the wac repo, wall time vs http-backend | 4.9× | 5.3× | 11× |
| the wac repo, CPU vs http-backend | 18× | 13× | 19× |

**Memory is the largest gap.** The wac server sits at 180–330 MB, most of it the Node runtime and wasm heap,
and peaks at 833 MB serving the 39 MB clone. git peaks at 150 MB.

## Where the time goes, and what would close the gap

The costs are in the algorithms, not the protocol. Each one has a known fix:

1. **No delta-base cache.** wac's `readObject` resolves a deltified object by re-inflating its whole base
   chain every time, and git's chains run 50 deep. A full clone walks every commit and tree, so it inflates
   the same bases over and over. git keeps a cache of recently resolved bases. Adding one is the biggest
   single win for clone time.
2. **Walking whole histories.** To find what the client already has, the server walks the entire history
   behind every common commit. A push does the same behind every existing ref, to know where its connectivity
   check can stop. On wac's 2,000-commit history, that is most of the 2 s fetch and the 5 s push. git walks
   both sides together by commit date and stops early. With a commit-graph file, it does not need to inflate
   commits at all.
3. **Whole files in memory.** Packs are read whole into the heap, and so are request and response bodies.
   That is most of the peak RSS. Streaming the response and reading packs a window at a time would bound it.
4. **The engine.** Some gap will remain: this is a GC language compiled to wasm on V8, against C. How much of
   the 13–19× is the engine and how much is 1–3 is not measured here. Fixing 1–3 first is what would tell.

A first version of the push path showed how much the algorithms matter. It used wac's `indexPack`, whose
reference-delta resolution is quadratic, and a 4 MB push of 400 objects took more than five minutes. With
`src/indexpack.wac`, the same push indexes in 180 ms.
