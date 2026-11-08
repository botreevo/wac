# 0431d — two files' private generics of one name share their instances

- **Status:** open
- **Reported by:** cloud session, narrowing a report from wac-kps
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
// ---- a.wac ----
struct X { i32 a; }
struct Box<T> { T v; }
export struct Holder { Box<X> bx; }
export Holder mk() { return Holder(Box<X>(X(5))); }
// ---- b.wac ----
struct Box<T> { T v; }
export struct X { string b; }
export struct HB { Box<X> bx; }
export HB mkb() { return HB(Box<X>(X("rr"))); }
// ---- main.wac ----
import { mkb } from "./b.wac";
import { mk } from "./a.wac";
export i32 f() { return mk().bx.v.a + mkb().bx.v.b.len(); }
```

`wac check` is clean; the build answers *a construction of Box<X> with 1 of 2 fields*. Each file's `Box` is its
own, and so is each `X`, so there are two instances, and the emitter makes one of them. With one shared `Box`
imported by both files it builds.

## Notes

An instance is named from its template's spelling and its arguments' spelling — `Box<X>` — where the key of each
(`Box@3<X@3>`) is what tells them apart. wac-kps met invalid wasm with two private `struct Outgoing`s in two packages
(*struct.new expected type (ref null 204), found … (ref null 216)* in a coroutine), which may be this or a relative;
the plain-struct shapes tried (held directly, in arrays, in a shared generic, across an await) all build.
