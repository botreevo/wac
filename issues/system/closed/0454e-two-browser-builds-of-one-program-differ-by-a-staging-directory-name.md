# 0454e — two `--target browser` builds of one program differ by a staging directory's name

- **Status:** closed 2026-11-10 (cloud) — `build.ts`'s `bundle` drops the name; `layout.test.ts`
- **Claimed by:** wac2
- **Reported by:** reckon2, through the coordinator
- **Date:** 2026-11-10
- **Kind:** bug
- **Symptom:** a build that is not byte-reproducible

## Reproduction

Two `--target browser` builds of the same program, through `packages/platform/build.ts`, came out differing only in a
directory name embedded in `launcher.js` and `worker.js` — once as a comment, once as the key the bundler's module table
is indexed by: `wac-app-<random>` when the build had no cache key (`Deno.makeTempDir`), and `.cache/stage/<key>` when
it had one. reckon's `release.sh` rewrote it as a workaround.

## Why

`produceApp` stages the generated glue and the entry scripts in a working directory and bundles from there, and the
bundler writes every module's path — the staging directory's included — into what it emits.

## Fix

`bundle` replaces the staging directory's own name in the bundler's output with `wac-app`. The name is unique to the
build, so the replacement touches nothing else, and a build's bytes no longer depend on where it was staged.
`packages/platform/test/layout.test.ts`'s third test builds both layouts and finds neither a random staging name nor a
cache key in any of the text; it fails without the change (*"the cache key's staging name is in the output"*).

Still path-dependent, and not this issue: the bundler's paths are relative to the directory the build ran from, so a
build from another working directory names the host's modules by another relative path.
