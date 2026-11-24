# 0380d — a mount over a relative view serves the whole host, and `..` climbs out of a mount

- **Status:** closed 2026-11-10 (cloud) — `std/platform.wac`: `Files.under`, `mountedPath`;
  `packages/platform/test/wac/memstore_test.wac` `test_a_view_under_a_directory_cannot_be_left`
- **Reported by:** wac-eth's reckon session, building a hermetic runner
- **Date:** 2026-11-10
- **Kind:** security
- **Symptom:** a child reads files its parent meant to keep from it

## Reproduction

A parent spawns a child holding `Files.mounted([Mount("/in", sys.files().relativeTo(DIR).readOnly())])`. On the Node and
the wasmtime host alike, the child sees:

- `/in/ok.txt`, which is `DIR/ok.txt`: *not found* (Node: *ENOENT … open '/ok.txt'*);
- `/in/etc/hostname`: the host's `/etc/hostname`;
- `/in/../etc/hostname`: the host's `/etc/hostname` again;
- `/etc/hostname`: refused, *no mount answers it* — the only one that behaved.

## Why

Two things, each reasonable alone.

A mount hands its files a path from its own root — `/in/etc/hostname` reaches the mount as `/etc/hostname` — which is
what every mount in the tree wants: a memory store, `/proc`, `/dev` each see their own `/`. And `relativeTo` is a shell's
current directory: a relative path is taken from `dir`, and an absolute one goes on unchanged, which a shell needs —
`cat /etc/x` in any directory reads `/etc/x`. Put together, the mount's absolute path went straight through the relative
view to the host's root, and `dir` itself was reachable by no path at all. The look of the expression — a directory,
read-only, mounted — said jail, and nothing in the library could make one.

Separately, the mount table chose a mount by the path as written, so `/in/../etc/hostname` matched `/in` and handed its
files `/../etc/hostname`.

## Fix

- **`Files.under(dir)`**: every path, absolute or relative, taken from `dir`, with `..` stopping there. Composed
  (`hostGrants` 0), because a host grant cannot express a directory boundary — a child handed it is served every request
  by its parent. `Mount("/in", fs.under(dir))` is the jail the reproduction meant.
- **The mount table normalises an absolute path before choosing a mount**, so no `..` climbs out of one.
- `relativeTo`'s documentation says it is not a boundary, and the test pins that it is not, so the difference stays a
  decision. Changing `relativeTo` itself would break every shell built on it.

A link inside `dir` that the files beneath follow is still followed; a host that resolves links can lead out through
one. Keeping a child from that needs the host's help (`openat2`'s `RESOLVE_BENEATH`, or equivalent) and is not done.
