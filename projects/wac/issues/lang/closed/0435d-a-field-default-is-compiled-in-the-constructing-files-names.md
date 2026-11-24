# 0435d — a field's default is compiled with the constructing file's names

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `emitFieldDefault` and `Env.fieldInitFiles`; `packages/wacc/test/wac/fieldinit_test.wac`
- **Reported by:** wac-kps (two private `struct Outgoing`s, in `packages/webrtc` and `packages/quic`)
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** invalid wasm, with no diagnostic

## Reproduction

```wac
// ---- holder.wac ----
import { Vec } from "core";
struct X { i32 a; }
export struct Holder { i32 k; Vec<X> q = Vec<X>.create(); Holder make(i32 k) { return Holder { k: k }; } }
export i32 count(Holder h) { h.q.push(X(5)); return h.q.len() * 10 + h.q.get(0).a; }
// ---- other.wac ----
import { Vec } from "core";
export struct X { string b; }
export struct Box { Vec<X> xs = Vec<X>.create(); }
export i32 boxed() { Box b = Box {}; b.xs.push(X("q")); return b.xs.len(); }
// ---- main.wac ----
import { Sys } from "std";
import { boxed } from "./other.wac";
import { Holder, count } from "./holder.wac";
export async i32 main(Sys sys) { await; Holder h = Holder.make(1); await; return count(h) + boxed() * 100 - 115; }
```

`wac check` is clean and the build succeeds; the engine refuses the module — *struct.new[1] expected type (ref null 47),
found call of type (ref null 46)* in `__wacCo___wacMain`. wac-kps met it as the same error in `dial`'s coroutine, where
`Association` (webrtc) holds `Vec<Outgoing>` and the program also reached quic's `Outgoing`.

## Why

`h` lives across an `await`, so it is a cell of the coroutine's frame, and the frame starts each cell at its type's
default — for a struct, one built with its field initialisers. `emitFieldDefault` compiled the initialiser with its
own file's text but in `env.curFile`, which was the async function's file; `fileFor` answers `curFile`, so `X` in
`Vec<X>.create()` resolved as the async function's file sees it — the other `X` — and `Holder`'s field got a vector
of the wrong type.

## Fix

Each initialiser records the file it was written in (`fieldInitFiles`, beside `fieldInitSrcs`), and `emitFieldDefault`
compiles it there.
