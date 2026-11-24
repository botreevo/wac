# 0463d — `wac update` does not follow git's `insteadOf`, so a pin not yet synced to GitHub cannot be fetched

- **Status:** closed 2026-11-11 (cloud) — `packages/wacpkg/src/mirror.wac`, used by `packages/wacpkg/src/fetch.wac`;
  `packages/wacpkg/test/wac/mirror_test.wac`
- **Reported by:** wac1, from wac2's wac-web pin a859d17 (the agent-coordination session)
- **Date:** 2026-11-11
- **Kind:** missing feature
- **Symptom:** a fresh `wac update` fails with *upload-pack: not our ref* while `tools/fill-cache.sh` succeeds

## Reproduction

`wac.json5` pins `web` at `https://github.com/voltrevo/wac-web.git` @ a859d17, a commit pushed to git.voltrevo.com
and not yet synced to GitHub. With `sh tools/use-mirror.sh` run and an empty cache, `wac update` asked GitHub and
answered *wacfetch: web: no pack in the reply: the server said: upload-pack: not our ref a859d17…*; the browser lanes
and `tools/wac/webpolicy_test.wac` then failed for want of the dependency. `sh tools/fill-cache.sh` filled the same
commit, because `git` obeys the setting.

## Why

Pins name GitHub and development fetches from git.voltrevo.com through one git setting, `url.<base>.insteadOf`
(`CLAUDE.md`, `tools/use-mirror.sh`). `wacfetch` speaks smart HTTP itself and read no git configuration, which both
scripts said in so many words.

## Fix

`mirror.wac` reads the `insteadOf` rules git would apply — `packages/git`'s `configChain` (system, XDG, `~/.gitconfig`)
and then the `GIT_CONFIG_COUNT` pairs — and applies the longest matching prefix, as git does. `fetchOne` fetches from
the rewritten url and says so (*fetched from https://git.voltrevo.com/wac-web.git, git's url.insteadOf for it*); the
cache path and the lock keep the url as pinned, which is what a build looks a dependency up by. End to end, the case
above with an empty `WAC_HOME` fetched a859d17 from the mirror into the GitHub-keyed cache directory.
