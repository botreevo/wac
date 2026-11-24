# 0412a — a block-local shadowing a parameter in an async function emits invalid wasm

- **Status:** closed 2026-11-10 (cloud) — `asynclower.wac`'s `machineOf` seeds `uniqueLocals` with the parameters; `spec/cases/0887`
- **Reported by:** agent-a
- **Date:** 2026-10-27
- **Kind:** bug
- **Symptom:** invalid wasm

## Reproduction

```wac
struct P { i32 n; }
struct Q { string s; }
async i32 tick() { return 1; }
i32 use(P p) { return p.n; }
async i32 run(P out) {
  if (out.n > 0) {
    Q out = Q("shadow");
    await tick();
    if (out.s.len() == 0) { return 9; }
  }
  await tick();
  return use(out);
}
export async i32 main() { return await run(P(3)); }
```

Expected: answers 3 — the inner `out` is a `Q` for its block, and after the block `out` is the parameter again.
Actual: `wac check` passes and the engine rejects the module: *call[…] expected type (ref null N), found array.get
of type (ref null M)* — the state machine keeps both `out`s in one frame slot, so the read after the block takes the
`Q`'s slot type where `use` wants a `P`.

## Notes

Found as `$lambda$3/29:1024` in `packages/box/src/applets/gets.wac`, where a `ClientStep out` inside the request
block shadowed the `Output out` parameter (design/system/0013 step 5 gave applets an `Output out`). Renamed there.
A synchronous function with the same shape is fine; the frame of an `async` one is keyed by name.

## Fix

A machine keeps each local in a cell named after it, declared for the whole function, and `uniqueLocals` renames a local whose name an earlier one used — but it started knowing no names, so a block-local named like a parameter kept the name, and its cell shadowed the parameter after the block as well. The parameters are seeded as names already used.
