# wac-eth

Read README.md first. This is what it does not say.

## Layout and rules

- **One project, one pin.** There is one `wac.json5` and one `wac.lock`, at the root, so `@/` means this root
  everywhere — `@/lib.wac`, `@/wacuum/src/lib.wac`. Do not add a `wac.json5` inside a member: it would become a
  project of its own, with its own `@/` and without the `wac` import, and the one-pin property would be gone.
- **What comes from wac comes through `"wac"`** — `crypto`, `bls`, `json`, `codec`, `bytes`, `http`, `wactest`.
  A name wac's `lib.wac` does not export is a change to wac's `lib.wac`, made there; do not copy the file here.
- **What is ours comes by path**, or through `@/lib.wac` for the namespaces (`rlp`, `mpt`, `ethrpc`, …).
- **One exception: `reckon/examples/`** holds example apps that are projects of their own on purpose — a build
  statement covers a source tree with its own pinned dependencies — and `wac.json5` excludes them from `wac check`.
- **wacuum and the devnet keep their own `CLAUDE.md`**, written when each was a repository; the parts about pins
  and dependencies are updated, the rest still holds.
- **wac is unstable by choice, and so is this**: when nothing needs a thing, delete it (wac's `CLAUDE.md` has the
  rule in full). The one exception on purpose is the coverage ledgers, kept until `issues/open/1001` brings them
  back.
- Issues and design documents keep wac's numbers where they came from wac; new ones start above 1000.

## Running things

    sh tools/deps.sh                     the pins into wac's package cache
    wac task test                        every unit test
    wac task check                       the whole project
    wac task wacuum:fixtures             execution-spec-tests, once (250 MB), then wacuum:statetests and friends
    wac task devnet:build                wacuum-devnet/dist/devnet

Some package tests ask an oracle written in TypeScript (`packages/mpt/test/oracle.ts`), which wactest runs with
`deno`: have it on PATH.

## Moving the wac pin

`ref` in `wac.json5` names the branch, `commit` in `wac.lock` the commit; move the commit, run `sh tools/deps.sh`
and `wac task test`.
