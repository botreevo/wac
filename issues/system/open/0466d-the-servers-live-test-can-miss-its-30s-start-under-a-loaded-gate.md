# 0466d — the server's live test can see its Deno server say nothing for 30 s under a loaded gate

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
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
