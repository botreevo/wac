# 0459d — an out-of-range float-to-int conversion traps as a different `TrapKind` on wasmtime

- **Status:** closed 2026-11-10 (cloud) — `native/src/main.rs`'s `trapped_at_trunc`;
  `packages/platform/test/wac/ended_test.wac` (`convert` and `overflow` in `ended_probe.wac`)
- **Reported by:** reckon1
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** `Child.ended()` disagrees across hosts, against `§wac-std-child-ended-q2v8mtf`

## Reproduction

```wac
import { Sys } from "std";
export i32 main(Sys sys) { f64 x = 1.0e20 + (sys.args().len() as f64); i32 y = x as! i32; return y; }
```

Spawned as a child and asked `ended()`: `Trapped(BadConversion, …)` on V8 (*float unrepresentable in integer
range*), `Trapped(IntegerOverflow, …)` on wasmtime.

## Why

wasmtime raises `Trap::IntegerOverflow` for an out-of-range `iNN.trunc_fMM_s/u` as well as for `INT_MIN / -1`, and
keeps `BadConversionToInteger` for NaN; `trap_kind` mapped `IntegerOverflow` to its kind unconditionally.

## Fix

The host keeps the module's bytes beside it, and an `IntegerOverflow` whose innermost frame stopped at a trunc opcode
(0xA8–0xAB, 0xAE–0xB1) is `BadConversion`, as V8 says it. The division stays `IntegerOverflow`. The spec rule now
says which is which.
