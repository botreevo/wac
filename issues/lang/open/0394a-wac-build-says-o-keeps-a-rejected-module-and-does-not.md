# 0394a — When the engine rejects a built module, `wac` says `wac build … -o out` keeps it, and no file is written

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** agent-a
- **Date:** 2026-10-21
- **Kind:** bug
- **Symptom:** wrong answer

## Reproduction

```wac
// Any program whose emitted module the engine refuses — e.g. one that hits a swallowed decline (fixed in
// 9580a3798, so this now needs another invalid-wasm bug to show).
```

Expected: the module on disk at `out.wasm`, so the rejection can be inspected.
Actual: the message promises it; nothing is written.

## Notes

Found while bisecting the seed failure during the 2026-10-21 bug hunt. The message is in `packages/wac/src`.

## The promise is gone — 2026-11-10

The v8 host's message no longer says `wac build … -o out` keeps the module (`native/v8/src/main.rs`, with
`issues/system/0365a`): it names the engine's own reason instead, and says when the rejected module was the binary's
seed. What this issue asks for is still open — the rejected module written to disk so it can be inspected.
