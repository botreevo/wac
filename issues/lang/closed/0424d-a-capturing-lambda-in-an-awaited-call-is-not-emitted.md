# 0424d — a lambda that captures a local, written in an awaited call, is not emitted

- **Status:** closed 2026-11-04 (cloud) — `packages/wacc/src/asynclower.wac`, `takePre`; `spec/cases/0860`
- **Reported by:** wac-ide (`docs/wac-wishlist.md`, item 9)
- **Date:** 2026-11-04
- **Kind:** bug
- **Symptom:** emit failure

## Reproduction

```wac
async i32 run(fn<void(i32)> progress) { progress(1); return 1; }

export async i32 go() {
  string name = "x";
  i32 n = await run((i32 done) => { string s = "\{name} \{done}"; });
  return n;
}
```

`wac check` is clean; `wac compile` answers *cannot emit — `__wacAw0`, which is read here and is neither a
local nor a module constant this emitter can find*. With `name.len()` in the lambda instead, *a call to
`.len`, which this expression is emitted as and which is not in the program*. The same lambda held in a
local first, `fn<void(i32)> f = …; await run(f);`, compiles; so does one that captures nothing. The three
statement shapes an `await` heads — `T x = await e;`, `return await e;` and `await e;` — all had it.

## Why

**A lambda reads a machine's locals through locals of its own.** Every local of an `async` function is a
cell once the function is a state machine, and a lambda copied into it captures a cell through a fresh
local declared just before the statement holding it (`__wacAwK = name`, in `subExpr`'s `Ident` arm). Those
declarations go on the copy's list of statements to emit ahead, and `subStmt` writes them out. A statement
headed by `await` is not copied by `subStmt`, though: `lowerOne` copies its operand itself and hands it to
`lowerSuspend`, which built the suspending state without ever reading the list. The lambda read a local
that was never declared — or, for a method on it, one whose type was never known.

## Fix

`lowerOne` takes what copying the operand declared (`takePre`) and `lowerSuspend` writes it at the top of
the suspending state, before the operand runs: where the statement's own copy would have put it.
