# 0434d — `"x" as string?` is not emitted

- **Status:** closed 2026-11-08 (cloud) — `emit.wac`'s `unsupportedExpr`, `Cast` arm; `spec/cases/0870`
- **Reported by:** wac-sqlite
- **Date:** 2026-11-08
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
export i32 main() {
  string? a = null;
  if (true) { a = "x" as string?; }
  return (a ?? "").len();
}
```

`wac check` is clean; the build answers *cast to an unsupported type*. `(try f()) as Value?` builds.

## Why

The emitter drops a reference's own `?`, so the target reads `string`, and the list of cast targets it accepts named
arrays, structs, numbers, `bool`, boxes and unions — and not `string`, which is spelled apart from the arrays it is.

## Fix

`string` is on the list. The conversion emits nothing, as it does for a struct.
