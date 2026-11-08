# 0428d — a float literal expression beside an `f32` is emitted at `f64`, and the module will not load

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `operandType` and `emitAt`; `spec/cases/0867`
- **Reported by:** cloud session, met while testing 0427d
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
export i32 f() {
  f32 r = 1.5;
  f32 s = 0.0 - 2.0 + r;                  // local.set expected f32, found f64.add
  return r == 0.0 - 2.0 ? 1 : 0;          // f32.demote_f64 expected f64, found f32.sub
}
```

## Why

`0.0 - 2.0` has no type of its own (spec ch09 `§wac-float-literal-ctx-8dqm2vw`), and `typeOfE` answers its
family's `f64` for want of anything better. `operandType` took that as the left operand's type ahead of the
`f32` beside it; and `emitAt` steered the expression to `f32` and then converted it from the `f64` it
reported, demoting an `f32`.

## Fix

`operandType` gives a literal expression the other operand's type, as `typeOfE`'s `Binary` arm already did;
`emitAt` converts nothing after emitting a float literal expression at the float type wanted.
