# 0456d — `wac update` drops a lock entry's fields it does not know

- **Status:** closed 2026-11-10 (cloud) — `packages/wacpkg/src/lock.wac`'s `LockEntry.extra`;
  `packages/wacpkg/test/wac/lock_test.wac` `test_an_entry_keeps_the_fields_it_does_not_know_while_its_commit_stays`
- **Reported by:** wac-eth's reckon session
- **Date:** 2026-11-10
- **Kind:** missing feature
- **Symptom:** a tool's annotation of `wac.lock` undone by the next rewrite

## Reproduction

A `wac.lock` entry carrying a field of its own — reckon records each dependency's unixfs root as `cid`:

```json5
{ imports: { a: { git: "https://e.test/a", ref: "main", commit: "aaaa…", cid: "bafy…" } } }
```

Anything that rewrites the lock (`wac update`) wrote it back without `cid`, and reckon's `deps check` refused it.

## Why

`readLock` read an entry into `LockEntry { name, git, ref, subdir, commit }`, and `writeLock` wrote exactly those. An
entry the plan kept was the struct, so whatever else it had said was gone before anything was written.

## Fix

`LockEntry.extra` keeps the entry's other members as they were written, one to a line, and `writeLock` puts them back
after `commit`. An entry the plan uses keeps them; one whose commit changes (`CREATE`, `REFRESH`) drops them, since what
they said was about the old commit — a tool that records something per commit records it again.
