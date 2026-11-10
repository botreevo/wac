# Dependencies pinned by CID

v1's `reckon lock` (`src/lock.wac`) pins each `wac.lock` entry by a tree hash of its own (kt1). This is the same
idea in v2's terms. Each entry is pinned by a **CID under the unixfs-v1-2025 profile**, the same identifier the
store, mirrors, recipes and claims already use. A dependency can then be fetched from a mirror by CID, endorsed by
CID, and named as a derivation's input, with no second hash function. It is one of the two things J says v1 still
does that v2 does not (docs/decisions/J-v1-code.md).

## What is pinned

    "web": { "git": "https://git.voltrevo.com/wac-web.git", "ref": "…", "commit": "fb7b45cc…",
             "cid": "bafybeibd4iu277zabfxwii2t3hfjf5vinpd6ih77zvdpnw6lii2wa2igd4" }

`cid` is the root of the commit's whole tree, as `obj add-git REPO COMMIT` imports it. That is also what wac's
package cache holds for the entry, less one file: the cache's completion marker, an empty `pack.pack` at the top,
which the cache adds and the commit doesn't have. Measured for wac-web at `fb7b45cc`:
- the cache directory as it is: `bafybeig77hl…`;
- the git commit: `bafybeibd4iu…`;
- the cache without `pack.pack`: `bafybeibd4iu…`, the same as the commit.

So the CID is computable from either source, and both must agree. A `subdir` mapping still pins the whole commit,
and the subdirectory is a path under it. `git` and `commit` stay, as where to look first.

wac reads a lock with unknown fields and ignores them, as v1's `tree` showed. **Open:** whether `wac update`, which
rewrites the lock, keeps `cid`. If it drops it, `pin` must be run after every `wac update`. `check` refuses a lock
with an entry that has no `cid`, so a dropped pin is noticed, not silently lost.

## Commands

A new `cmd/deps.wac`. The v2 code is not mixed into v1's `lock`, and the name doesn't collide with `src/lock.wac`.

- `deps pin [--lock F]`: for each entry without a `cid`, hash its cache directory (less the marker) and write the
  CID in. It never changes a `cid` that is there. It refuses a lock holding a field it doesn't know, rather than
  drop it on rewriting.
- `deps check`: hash every entry's cache directory and refuse any that differs from its `cid`, or has none. This is
  what a build should run first. v1 found that wac compiles from a tampered cache without noticing (README,
  finding 1), and this is the check for that.
- `deps fetch [--mirror DIR|URL]… [--git]`: for an entry not in the cache, get it by CID from the store or a mirror,
  with every block checked. Failing that, and with `--git`, clone the repository into a scratch directory and hash
  the commit there. Either way, install it
  into the cache, with the marker, only if it matches. A remote serving other bytes is refused before the cache
  holds them.
- `deps cids`: one `NAME CID` per entry.
- `deps admit ROLE --policy P [--mirror …]`: `claim admit CID ROLE` for every locked CID, under one policy. It reads
  the claims here and in the mirrors, but has no chain flags: for revocations proved on chain, run `claim admit` with
  them on each of `deps cids`. For
  example, `dependency: [{ endorsed: { by: ["reviewer"] } }]` requires that each dependency was reviewed. v1 had no
  equivalent: there, a pinned dependency was only the same bytes as before, never an admitted one.

## How it meets builddeps

`tools/builddeps.sh` lays the cache out under the input tree's `home/cache/git/…` by copying directories. With CIDs
in the lock, that input can be assembled from the locked CIDs alone, and the recipe's input names each dependency by
the CID the lock pins. A policy's `derived` rule can then require, through `slots`, that every dependency slot is
admitted as `dependency`, so a build is admitted only if what it was built from was. The marker is part of what the
compiler sees in the cache, so the tree builds lay out has it. That changes the layout's CID but not the
dependency's, and a recipe names both.

## Built

The code is about 330 lines:
- `src/deplock.wac`: the lock, read and written with `cid`, v1's fields carried through;
- `cmd/deps.wac`;
- `importDirExcept` in `packages/ipfs`: `importDir` leaving out named top-level entries.

`tools/deps-lock.sh` (task `reckon:deps`) runs on wac-web, as wac.lock pins it, in a cache of its own, and passes 14
of 14:
- pin gives the CID that `obj add-git` gives for the commit, and a second pin changes nothing;
- check passes the cache, and refuses one byte added or an entry without a `cid`;
- fetch from a mirror into an empty cache gives the same files and checks;
- a mirror with one block changed is refused, and nothing is marked complete;
- fetch from git checks, and a pin the commit isn't is refused with nothing kept;
- admit refuses the dependency unreviewed (4) and admits it once the reviewer endorses its CID;
- a lock with an unknown field isn't rewritten.
