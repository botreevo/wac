# 1001 — the coverage ledgers run only inside wac's checkout

- **Status:** open
- **Kind:** missing feature, from the move
- **Date:** 2026-11-09

Each package came with `test/cov_ledger.wac` and `test/cov_exercise.wac`, which in wac ran as
`wac task coverage:<package>` and held each package's branch coverage to a pinned floor. They drive wac's
`tools/wac/covledger.wac`, which is wac tooling rather than a package, finds the `wac` binary at
`native/v8/target/release/wac` under the current directory, and is not in wac's `lib.wac`.

So they cannot run here yet, and `wac.json5` excludes them from `wac check` rather than let them fail it. They
were kept rather than deleted because the pinned floors are data: each is a measurement somebody made.

Done when `wac task coverage:<package>` runs here for all seven and reports the floors the ledgers pin — most
likely by wac exporting `covledger` beside `wactest`, with the binary found on PATH.
