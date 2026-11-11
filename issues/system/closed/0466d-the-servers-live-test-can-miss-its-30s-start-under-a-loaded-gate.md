# 0466d — the server's live test can see its Deno server say nothing for 30 s under a loaded gate

- **Status:** closed 2026-11-11 (cloud) — `packages/server/src/main.wac` replaces packages/server/host/serve.ts (deleted
  2026-11-11); `packages/server/test/wac/live_test.wac` and `packages/http/test/wac/interop_test.wac` build it with
  `builtApp` before starting it
- **Reported by:** wac1
- **Date:** 2026-11-11
- **Kind:** flaky test
- **Symptom:** a red gate that a rerun turns green

## What happened

The full gate for 94e1ad898 (which changes nothing under `packages/server`) failed one test:

```
[w2] FAIL test_nodes_http_client_is_satisfied_too — 1 failed: node: the server started — : expected true
```

The same file run alone a minute later passed, 9 of 9 in 27.6 s.

## What the message says, and what it does not

`startServer` in `packages/server/test/wac/live_test.wac` starts `deno run -A packages/server/host/serve.ts <port>` and
waits up to **30 s** for `listening on` in its log. The text after *"the server started —"* is the log, and it was
**empty**: the server printed nothing at all — not a bind error, not a stack — in 30 s. So this is not obviously a
deadline cut too fine for a slow start that was under way; a cold `deno run` doing its type-check and module load on a
box running four suite workers is one reading, a port handed out by `Held.take` and released before the server bound it
is another (that would usually log an error, though). Nobody has told them apart yet.

## What would settle it

- Record the server's exit status and stderr separately from its log when the wait fails, so the next failure says
  whether it was still running.
- If it was still starting: the deadline, or warming `serve.ts`'s module graph once before the test's servers start.
- If it had exited: what it said.

Also on the porting list: `serve.ts` is a TypeScript server the policy of 2026-11-11 would have be wac, which would
remove the cold Deno start from this path altogether.

## Again, 2026-11-11, in another package

The gate for bd9165da8 failed `packages/http/test/wac/interop_test.wac`'s `test_wac_client_to_wac_server_the_loop_closes`
the same way — *"the wac server never listened: "*, the log empty — and the file passed alone, 5 of 5. Earlier the same
day it had failed once more and passed on a rerun. Two packages, one shape: a server started from a test that prints
nothing before the test gives up, under a loaded gate. The fix is likely shared.

## The likely cause, read from the server (2026-11-11)

`packages/server/host/serve.ts` prints `listening on` only after
`await wacBind("packages/server/test/probe.wac")` — it *compiles a wac program* through `harness/wacBind.ts` before it
opens the socket. Cold, or with the build cache contended by four gate workers, that compile alone can outlast 30 s, and it
prints nothing while it runs — which is the empty log. A third occurrence the same day, in the gate for a9d1c1d9c
(`test_fetch_is_satisfied_by_every_route`), passed alone 9/9 in 29.5 s — close to the deadline even unloaded.

The fix the 2026-11-11 policy points at fixes this too: the server's accept loop in wac (its own header notes ten wac files
already run accept loops, and that "TypeScript" here is a choice, not a constraint), started with `wac run`, so there is no
compile on the critical path and no TypeScript driving wac.

## Fixed (2026-11-11)

The accept loop is wac: `packages/server/src/main.wac` — `listen`, an `accept` loop that starts each connection's machine
unawaited, the buffer-then-`serve` discipline, and the three limits on its command line, with `Clock.within` bounding each
`recv`. Both tests build it with `builtApp` *before* the start clock runs, so what the 30 s / 20 s waits now cover is a
native program binding a socket. Unloaded, `live_test.wac` went from 29.5 s to 1.6 s (9/9) and `interop_test.wac` passes
5/5 in 0.9 s. `wac task serve` runs the same file under `wac run`.
