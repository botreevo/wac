# 0440d — a checked cast out of a union-typed field casts nothing

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `emitConversion`; `spec/cases/0875`
- **Reported by:** the "WAC programs on ESP32" session
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
struct Box { i32 v; }
struct Holder { union<i32, Box> u; }
static Holder H = Holder(Box(5));
export i32 s3() { return match (H.u) { i32: -1, Box: (H.u as! Box).v, }; }
```

Builds; the engine refuses it — *struct.get[0] expected type (ref null 1), found struct.get of type anyref*. Not the
static: a local `Holder` does the same, and so does `Box b = h.u as! Box;`.

## Why

`emitConversion` emits `ref.cast` for a cast whose source is `anyref` or a struct the target descends from. A union
is an `anyref` in the module, but the source type of `h.u` is the union's own name, which was neither, so nothing was
cast.

## Fix

A union source is cast as an `anyref` one is.
