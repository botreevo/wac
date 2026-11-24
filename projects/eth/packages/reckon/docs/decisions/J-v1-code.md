# J: the v1 code: keep, quarantine under v1/, or delete

**Decide:** what happens to the first round (`reckon` the command: tree hashes, locks, `TrustRegistry.sol`) now that
the second round (`claim`, `derive`, `Registry.sol`, the light client) does admission end to end.

## What v1 is, exactly

| Kind | Files (lines) |
| --- | --- |
| Library | `src/tree.wac` 183, `src/walk.wac` 151, `src/lock.wac` 183, `src/statement.wac` 223, `src/build.wac` 96, `src/policy.wac` 297, `src/registry.wac` 139, `src/trust.wac` 172 |
| Contract | `contracts/TrustRegistry.sol` 75, `contracts/TrustRegistry.bin` |
| Command | `cmd/reckon.wac` 420 |
| Tests | `test/tree_test.wac` 100, `lock_test.wac` 35, `statement_test.wac` 76, `policy_test.wac` 152, `trust_test.wac` 24 |
| Tools | `tools/e2e.sh` 179, `tools/agree.sh` 17, `tools/wallet/` 54 |
| Example apps | `examples/hello`, `examples/notes`, about 2,200 lines, used only by `e2e.sh`, already excluded from `wac check` |
| Records | `docs/e2e-run.txt`, `docs/report.html`, `docs/notes-verified.png`; `docs/wacc-cases/` (compiler bugs found while writing `trust.wac`) |
| Tasks and prose | `tasks.json5`: `reckon:build`, `reckon:e2e` (and `reckon:test` runs v1's tests); `README.md`: "The first round…", "Findings worth acting on", the v1 rows of its file table; `docs/registry2.md` line 4 |

**Shared with v2, so not v1's to move:** `tools/liar.mjs` (the lying node; `registry2.sh`, `byname.sh` and
`anchor.sh` use it) and `tools/oracle` (its `node_modules` serve v2's wallets).

**The one tie from v2 into v1:** `unhex` and `hex` in `src/statement.wac`, imported by `src/registry2.wac`,
`src/policyfile.wac`, `cmd/claim.wac`, `cmd/derive.wac` and `cmd/registry2.wac`. Nothing else in v2 imports v1.

**What only v1 can do today:** `reckon run` (fetch a named app, verify it, write it out and open it), and
`src/lock.wac` (pinning `wac.lock` dependencies by tree hash). Everything else v1 does, v2 does more strictly.

## Options

| | Keep in place | Quarantine under `v1/` | Delete |
| --- | --- | --- | --- |
| What a reader sees | Two designs interleaved in `src/` and `cmd/`. "Which `policy`?" has two answers (`policy.wac`, `policyfile.wac`) | One design at the top, the old one clearly fenced | One design |
| Still builds and tests | Yes | Yes: it stays under the one `wac.json5`, so `wac check` and `reckon:test` still cover it | n/a |
| Reversible | n/a | Yes, a `git mv` | From history only |
| Loses | Nothing | Nothing | `reckon run` and `lock.wac` until ported; the recorded e2e run |
| Cost | None now; ongoing confusion, and every wac pin bump must keep v1 compiling | One commit, mechanical | One commit, plus porting first |

## What each option touches

- **Keep:** nothing. Optionally a line at the top of each v1 file saying it is v1.
- **Quarantine** (`packages/reckon/v1/`, same relative layout inside it):
  1. New `src/hex.wac` with `hex` and `unhex`; `statement.wac` re-exports or imports them. Change the import in
     `src/registry2.wac`, `src/policyfile.wac`, `cmd/claim.wac`, `cmd/derive.wac`, `cmd/registry2.wac`.
  2. `git mv` the v1 library, contract, command, tests, `e2e.sh`, `agree.sh`, `wallet/`, `examples/` and the three
     records into `v1/`. Fix their relative imports (`../src/…` stays correct if the layout is mirrored, and
     `e2e.sh`'s `$here` paths need `v1/`). `liar.mjs` and `oracle` stay in `tools/`; `e2e.sh` reaches them by
     `$here/../tools/`.
  3. `tasks.json5`: `reckon:build` → `v1/cmd/reckon.wac`, `reckon:e2e` → `v1/tools/e2e.sh`, and a `reckon:test`
     that runs `test` and `v1/test`. `wac.json5`'s exclude: `examples/**` → `v1/examples/**`.
  4. `README.md`: move the first round's sections to `v1/README.md` with a pointer; fix the file table.
     `docs/registry2.md` line 4 paths. `docs/wacc-cases` stays (it is about the compiler, not v1).
  5. Check: `wac check`, `reckon:test`, `reckon:e2e`, and one v2 script (`registry2.sh`) after the move.
- **Delete:** steps 1 and 4 of quarantine, then `git rm` the same set instead of moving it, and drop
  `reckon:build` and `reckon:e2e`. Before that, port what only v1 does:
  - `claim run SUBJECT ROLE --out DIR`: `claim admit`, then write the admitted tree out (about 60 lines; the fetch and
    the block checks already exist in `obj`). This is also K3's native helper.
  - Dependency pinning by CID: a lock whose entries are root CIDs under the unixfs profile, checked as `obj` checks a
    tree (about 100 lines), or wac's own lock if wac adopts CIDs.

## Recommendation

**Quarantine now; delete once `claim run` and a CID lock exist.** Quarantine costs one mechanical commit, removes the
two-designs confusion, keeps v1 compiling and tested (so nothing rots silently), and keeps the recorded run beside the
code that made it. Deleting today would drop the only working "run a named app" path, which K3 recommends keeping as
the native helper. The `hex` split is worth doing in any case: it is the one place v2 leans on v1.
