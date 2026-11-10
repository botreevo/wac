# 0006d — the package entry lives on the `lib` branch; it belongs on `master`

- **Status:** closed
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** task
- **Symptom:** another project can import wacuum only from a branch

## Reproduction

wac lets a project reach another project only through its `exports` (a file inside a nested project is
refused: *"reaches a file inside the nested project … import its directory, which gives its `exports`"*).
`master`'s `wac.json5` names none, so `wacuum-devnet` imports `wacuum` from the `lib` branch, whose one extra
commit adds `src/lib.wac` and `exports: './src/lib.wac'`.

Expected: `import { Engine } from "wacuum"` from `master`.
Actual: only from `lib`.

## Notes

Merging `lib` is the whole task; `src/lib.wac` exports one name per statement, as wac's own `lib.wac` does.
After it, `wacuum-devnet`'s `wac.json5` takes `ref: 'master'` and its lock moves to that commit.

## Resolution

`lib` is merged into `master` (`004c4fa`): `src/lib.wac` and `exports: './src/lib.wac'` are there, and
`wac check src/lib.wac` is clean against `master`'s sources. `wacuum-devnet` can take `ref: 'master'`.
