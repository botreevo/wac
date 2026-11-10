# 0460e — a page does not serve `CHILD_ENDED`, so a page's child cannot be waited for

- **Status:** open
- **Claimed by:** (nobody yet — add yourself before working it)
- **Reported by:** wac2, running the live browser tests in a cloud container for the first time (`0452e`)
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** a page that starts a process and awaits its exit gets an error instead of the code

## Reproduction

    $ deno test -A --unstable-net packages/platform/test/browser_live.test.ts
    error: Error: assertEquals failed — procs: its status
      got:  "a page does not serve request 74"
      want: "17"

`packages/platform/example/procs.wac`, built with `--spawn upper`, starts a copy of itself and shows `exit()`.

## Why

`Child.ended()` (wac `71bc06729`) added op `CHILD_ENDED` (74) and answers `Child.exit()` from it, on every host
wac carries. A page's host is not one of them: it is wac-web's `tools/build.wac`, pinned by `wac.json5`, and it
answers 74 with *a page does not serve request 74*. So every page that waits for a child broke with that commit, and
nothing noticed, because the live browser tests had not run anywhere since.

## Fix

wac-web's page host serves 74: the child's end as `Ended`, encoded as wac's own browser host
(`packages/platform/host`) encodes it, then wac's pin moves to that commit.
