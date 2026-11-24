# wac's projects

This repository holds several projects, each in `projects/<name>/` with its own `CLAUDE.md`, gate and versions.
Work inside one project as if it were its own repository: read its `CLAUDE.md`, run its gate (`tools/push.sh`
where it has one) from its directory. This file is only the rules that hold across them.

## Projects are separate

- **A project reaches another only through a pin**: a `wac.json5` import and `wac.lock` entry naming
  `https://github.com/voltrevo/wac.git` (`projects/repo/repository.txt` — that spelling, exactly), a commit and
  `subdir: ./projects/<name>`. Never a relative path out of its own directory, and never a second spelling of this
  repository's URL. A pin into wac from before 2026-11 has no `subdir`: wac was the repository root then.
- **A pin can only name a commit that already exists**, so a change across two projects is two commits at least —
  the change, then the pin bump in the project that uses it. That is what keeping their versions separate means.
- **A pinned commit must be in this repository's history.** `projects/repo/cmd/pins.wac` checks it, and every
  gate and CI run it: a pin to a commit that was rebased away, or to a branch that was never merged, builds on one
  machine and nowhere else. **So never rebase commits that are already pinned, and merge with merge commits** —
  a squash or rebase merge renames every commit in the branch, and every pin to one of them breaks.
- **The top level does not grow.** `README.md`, `CLAUDE.md`, `.gitignore`, `.github/` and `projects/`; a new
  project is a directory under `projects/`, and a new piece of shared tooling goes in `projects/repo`.

## Pushing

- Each project's gate pushes the repository's `master`. **A gate re-runs only for changes under its own
  directory**: when a push is refused and the merge brings only other projects' work, it pushes the merge
  without running again, because nothing it tested can have changed. Without that, one project's twenty-minute
  suite would never land while another project is pushing.
- Development happens on `https://git.voltrevo.com/wac.git`; the owner syncs the same commits to GitHub.
  `sh projects/wac/tools/use-mirror.sh`, once per machine, makes `git` fetch GitHub's URLs from there.

## The package cache

`wac` resolves a git import from `$WAC_HOME/cache/git/<url>/<commit>/`. `sh projects/repo/tools/fill-cache.sh`
fills it for every lock (each project's own `tools/fill-cache.sh` does its lock): pins into this repository come out
of local history with `git archive`, so a clone with full history needs no network for them. A shallow clone does
not have them — use a full one.

## CI

`.github/workflows/ci.yml` runs the pin check on every push and pull request, and `projects/<name>/tools/ci.sh` for
each project the change touches, with the `wac` that project pins. `pages.yml` publishes one site: wac's at the
root, a project with `tools/pages.sh` under `/<name>/`, and a project whose build fails keeps its last good one.
