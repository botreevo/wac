# 0450d — a relative entry built from `/` has every `@/` import leave its project

- **Status:** closed 2026-11-10 (cloud) — `packages/wacc/src/path.wac`'s `relativeTo`; `packages/wacc/test/wac/relativeto_test.wac`
- **Reported by:** wac-eth's reckon session, building inside its deterministic machine
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** a correct project refused

## Reproduction

A project with `wac.json5` (`{}`), `lib.wac`, and `sub/main.wac` importing `"@/lib.wac"`; from `/`:

```
cd / && wac check home/me/proj/sub/main.wac
wacc: @/lib.wac (from home/me/proj/sub/main.wac) leaves its project at ../home/me/proj
```

The same with an absolute entry checks clean, and so does the relative one from any other directory. reckon met it
because its machine runs the compiler with its working directory at the root.

## Why

A discovered `@/` root is brought back into the graph's key space with `relativeTo(base, abs)`, `base` being the working
directory. Its fast path asks whether `abs` starts with `base + "/"`, which from the root is `//` — no path starts with
that — and the climb that follows counted the root's one slash as a directory to leave. So `/home/me/proj` came back
`../home/me/proj`: a key for the import that was not the key its importer had, and the boundary check refused it.

## Fix

From the root, a path is itself without its leading slash. `relativeto_test.wac` pins the root and the cases around it.
