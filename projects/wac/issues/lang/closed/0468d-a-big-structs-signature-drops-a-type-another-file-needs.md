# 0468d — a struct whose signature names more than 64 types leaves an importer without one of them

- **Status:** closed 2026-11-13 (wac1) — `packages/wacc/src/api.wac` (`TyNameList`, `tyNames`, `closeOverSignatures`,
  `namesReachedThroughImports`); `packages/wacc/test/wac/reachedtypes_test.wac`
- **Reported by:** agent-w (wacuum), relayed by the coordinator
- **Date:** 2026-11-13
- **Kind:** bug (checker)
- **Symptom:** "no such field" on correct code, in a file that changed nothing

## Reproduction

wac-eth at `c15fb28`: add three fields to wacuum's `Engine` (`packages/wacuum/src/engine/engine.wac`, 38 fields, most
`Map<U256, …>`), e.g. `Map<U256, U256> extra1;` ×3 with three more `Map.create(hashU256, eqU256)` in its constructor.
`wac check packages/wacuum/src` stays clean; `wac check packages/wacuum-devnet` says

```
error: no such field
   --> packages/wacuum-devnet/src/explorer.wac:83:45
 83 |   return e.call(method, JsonValue.Array(ps)).result;
```

though `Answer.result` exists. Two extra fields were fine, and renaming wacuum's `Answer` made it go away.

## Cause

A file that imports a type also has to declare the types that type's signature mentions — `Engine.call` returns an
`Answer` the devnet never names — and `closeOverSignatures` gathers those mentions with `tyNames`, **into a list of 64
that dropped the 65th onward without a word**. `Engine`'s 41 fields, three names each, filled it before the method
return types were reached, so wacuum's `Answer` was never declared in `explorer.wac` — and there the bare name was
std's own `Answer` (`fault`, `text`, `bytes`, `n`, `m`, `flags`), reached through std's signatures. Hence a field
missing from a struct two files away, and hence the rename "fixing" it.

It looked like the checker's field table at first; a probe at every one of its silent-drop guards showed none full
(fields 640 of 38,060), and one at the report site showed the struct in hand was std's.

## Fixed

- `tyNames` appends to `TyNameList`, a list that grows; every caller uses it, so no signature can overflow it.
- `namesReachedThroughImports` sized a file's imports at a fixed 256 (silently ignoring the rest) and its reached
  names at 256: the imports are counted first now, and the names are a `TyNameList`.
- **No silent drops in the checker's declaration tables** — funcs, structs, fields, methods, enums, variants, aliases,
  renames, unresolved specifiers, unnameable types, the per-function names and warnings each returned quietly when
  full; each traps now (a bare `trap` — the bootstrap compiler cannot build one with a message), so a mis-sized
  table is a crash, not a wrong answer. `declarationsIn` counts a variant's payload fields twice, as they are declared twice (bare and
  `Enum.Variant`) — the one undercount the audit found there.
- The same pattern in diagnostics: a union placeholder's origins (a fixed 64, so the inferred union could miss a type)
  grow; the duplicate-member, duplicate-variant and payload checks are sized by what goes in, not 256 / 64.

`reachedtypes_test.wac` asks `closeOverSignatures` about a struct with 10, 40 and 400 two-name fields and a method
returning `Answer`; it fails at 40 and 400 against the old code. The devnet case checks clean.
