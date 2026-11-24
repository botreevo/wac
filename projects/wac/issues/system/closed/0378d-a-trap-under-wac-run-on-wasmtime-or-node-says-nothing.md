# 0378d — a trap under `wac run` on the wasmtime and JavaScript hosts says nothing

- **Status:** closed 2026-11-08 (cloud) — `native/src/main.rs` `run_child`; `packages/platform/host/children.ts` `WriteThrough.endWith`; `driver.ts` `__wacTrapSaid`, `provider.ts` `failureText`
- **Reported by:** wac-sqlite ("a program that overflows the stack exits 255 with no message")
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** a failure with no diagnostic

## Reproduction

```wac
i32 down(i32 n) { return n == 0 ? 0 : 1 + down(n - 1); }
export i32 main() { return down(100000000); }
```

`wac run` on the V8 host: *wac: deep.wac trapped: RangeError: Maximum call stack size exceeded*. On wasmtime: exit 1
and nothing. On Node: exit 255 and nothing. The same for `trap "boom"` and for a division by zero — every trap.

## Why

`wac run` starts the program as a child that inherits the terminal. Both hosts wrote the reason to the child's
**queued** error stream, which an inheriting child's parent never reads: wasmtime's `run_child` always wrote the
queue, and the JavaScript hosts' `WriteThrough` — the stream that writes through to the terminal — overrode `push`
but not `endWith`, the call the reason is written with, so it landed in the zero-sized queue underneath.

## Fix

- wasmtime writes the process's own error stream when the child inherited it, in the V8 host's words — *wac: prog
  trapped: why* — with the engine's root cause (`wasm trap: call stack exhausted`) rather than a page of backtrace.
- `WriteThrough.endWith` writes through.
- The JavaScript worker entries report the program's own `trap "…"` message when it gave one (`__wacTrapSaid`,
  read through the driver) rather than the engine's *unreachable*.

The JavaScript hosts still answer -1 (255) for a trapped child where the native ones answer 1; `packages/sh` reads
-1 as "no status of its own", so that is left as it is.
