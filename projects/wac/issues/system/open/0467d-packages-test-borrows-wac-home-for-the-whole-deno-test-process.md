# 0467d — `packages.test.ts` borrows `WAC_HOME` for the whole Deno test process, and deletes it

- **Status:** open — the fix waits for the step-6 design note (it threads a home through the build chain)
- **Reported by:** wac1
- **Date:** 2026-11-13
- **Kind:** bug (test isolation)
- **Symptom:** unrelated test files fail with "wac: cannot write …/wac-pinned%25-…/home/…: No such file or directory";
  leftover `wac-pinned%25-*` directories in the temp directory

## What happens

`packages/platform/test/packages.test.ts`'s `pinned()` builds a project whose dependency lives in a cache of its own,
and points the build at that cache with `Deno.env.set("WAC_HOME", `${dir}/home`)`, restoring it and removing `dir` in
`finally`. `Deno.env` is the process's environment, and `deno test` runs the suite's files in one process: every
other file that starts the `wac` command while it is set — `buildApp`, `buildNative`, `harness/wacFiles.ts`'s
`wacFilesFromCommand` — hands its child that home, and the home is deleted under any of them still running.

## Seen

The gate for 0fbfcea56 (2026-11-13): `box.test.ts` "wget writes one file…", `driver.test.ts` "an array the old list did
not name…", `layout.test.ts` "a browser build names no staging directory…" and `subprocess_profile.test.ts` (whose
subject inherited the variable) all failed with `cannot write /home/ubuntu/tmp/wac-pinned%25-…/home/cache/run/wac-run-….wasm`.
That was af7de1196's `wac run` hand-off, which then went to `$WAC_HOME/cache/run/` first; it goes to the temp directory
first now, so a run no longer fails on it.

It is older than that. The build cache writes under the same home, and a lost cache write is only a miss, so nothing
failed — but a cache write after the removal recreates `home/cache/build` inside the deleted temp directory, and about
forty `wac-pinned%25-*` directories dated from 2026-11-10 on were left in `/home/ubuntu/tmp` that way.

## The fix

Stop mutating the process environment: give `buildNative`/`buildApp` (and `wacFilesFromCommand`, which spawns the
command) a home, or an env, to hand the child, and have `pinned()` pass it. That is the build chain step 6 of
`issues/system/0161` is about, so it waits for that design note.
