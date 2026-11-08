# wac-git-server

A git server written in [wac](https://git.voltrevo.com/wac.git): every bare repository under a directory, over
git's smart HTTP protocol, for an unmodified `git` — clone, fetch, `ls-remote` and push, with nothing to configure
on the client.

```sh
wac task deps                 # wac's git, codec, crypto and gzip packages, at the pinned commit, into vendor/
wac task build                # dist/gitserve.wasm
wac dist/gitserve.wasm /srv/git --port 8080 --push-token-file token --create-on-push

git clone http://127.0.0.1:8080/project.git
git push http://me:$(cat token)@127.0.0.1:8080/new/thing.git main      # makes new/thing.git
```

You need the `wac` command, built from the commit in [`WAC_COMMIT`](WAC_COMMIT), plus git and curl for the tests.

## What it serves

```
GET  /                                            the repositories, one per line
GET  /<repo>/info/refs?service=git-upload-pack     the advertisement (protocol v2 when the client asks for it)
POST /<repo>/git-upload-pack                       ls-refs and fetch
GET  /<repo>/info/refs?service=git-receive-pack    the push advertisement
POST /<repo>/git-receive-pack                      the updates and their pack
```

`<repo>` may be named with or without `.git` and may contain `/`.

- **upload-pack, protocol v2** (`ls-refs`, `fetch`), which git speaks by default. The server says `ready` as
  soon as one `have` is in common, and the pack is what the wants reach beyond the commits the client has. An
  incremental fetch of three commits carries exactly their fifteen objects.
- **upload-pack, protocol v0**, for a client set to it. It does not advertise `multi_ack`. That is correct,
  but a stateless v0 fetch can be sent more than it needed; v2 has no such cost.
- **Packs are assembled from what is stored.** An object in a pack is copied compressed, as it is. A delta
  whose base is also being sent stays a delta: its `ofs-delta` is rewritten as a `ref-delta` naming the base,
  so it is valid wherever the base lands. Everything else is resolved and compressed afresh.
- **receive-pack**: create, fast-forward, force and delete, with `report-status`, `delete-refs`, `atomic`
  and `ofs-delta`.
  - Each ref moves by compare-and-swap on the old value the client sent, under a lock per repository.
  - A pushed pack is indexed, completed first if it is thin, and stored beside the others.
  - **Every object a new tip reaches is checked to be present before any ref moves.**
  - Ref names are held to `git check-ref-format`'s rules, so none reaches outside `refs/`.
- **HTTP**: chunked bodies (git sends a push larger than `http.postBuffer` that way) and gzip bodies (a large
  negotiation). The dumb protocol is refused.
- **Access**: reading is open. Pushing needs `--push-token-file`, which takes HTTP Basic with any user name
  and the token as the password, or `--anonymous-push`. `--create-on-push` makes a bare repository the first
  time an allowed pusher names one that is not there, with `HEAD` on the first branch pushed.

## Layout

| | |
| --- | --- |
| `src/serve.wac` | The protocol: advertisements, upload-pack v2 and v0, receive-pack, choosing and assembling packs. Functions from a repository and a request body to a response body, with no socket in them. |
| `src/indexpack.wac` | Indexing a pushed pack, in time proportional to its size (see below). |
| `cmd/gitserve.wac` | HTTP around it: routing, auth, chunked and gzip bodies, connection limits, open repositories kept between requests. |
| `test/e2e.sh` | Real git against the server (`wac task e2e`). |
| `test/*_test.wac` | Ref-name rules and v2 request parsing; the indexer against `git index-pack`, byte for byte (`wac task test`). |
| `bench/` | The comparison with git's own servers (`wac task bench`). |

**wac is fetched rather than imported.** wac's root library does not export its `git` package, and a `subdir`
import cannot reach the packages `git` imports (`codec`, `crypto`, `gzip`). So `tools/deps.sh` checks those
directories out of the commit in `WAC_COMMIT` into `vendor/wac`, which is gitignored, and the sources import
them by relative path. Nothing from wac is copied into this repository. If wac ever exports `git`, the script
and `vendor/` go away and the imports become `from "wac"`.

## Why it has its own pack indexer

wac's `indexPack` finds a `ref-delta`'s base by resolving and hashing other objects in the pack until one has
the right name, and it does that for every such delta. A thin pack's deltas are all of that kind, and every
push is a thin pack, so a push of n objects costs about n² SHA-1s of whole objects. A 4 MB push of 400 objects
was still going after five minutes.

`src/indexpack.wac` does what `git index-pack` does instead:

1. Inflate every object once.
2. Hash the whole objects.
3. Let each resolved object release the deltas waiting on it: by offset for an `ofs-delta`, by name for a
   `ref-delta`, both found in a map.

The same 4 MB pack indexes in 180 ms. `test/indexpack_test.wac` holds the `.idx` it writes to the one
`git index-pack` writes, byte for byte, for packs of offset deltas and of reference deltas. wac's own client
(`gitpull`) has the same quadratic indexer, and the fix belongs upstream.

## Tests

`wac task e2e` holds the server to real git, with about fifty checks. Each one is git's own opinion:
`git fsck --strict` on what arrived, `git rev-parse` against the source, and `ls-remote` over HTTP against
`ls-remote` on the directory. It covers:

- clones in both protocol versions;
- an incremental fetch, counted object by object;
- pushes with and without credentials;
- a 3 MB push, which arrives as a chunked body;
- a thin push, tags, deletion and a forced push;
- an atomic push with one bad update, which is refused whole;
- a repository created by its first push;
- a hand-written update from a stale old value, refused by the server. git's own client never sends one,
  because it checks a lease itself.

## Not served

- shallow and partial clones (`deepen`, `filter`);
- `want-ref`, push options and signed pushes;
- SHA-256 repositories;
- deltas computed afresh: an object stored whole or loose goes whole.

A repository's packs are held in memory while it is open.

**Any object may be wanted**, not only advertised tips. Nothing here hides refs, so git's
`uploadpack.allowAnySHA1InWant` check would have nothing to protect.

## Performance against git's servers

See [BENCHMARKS.md](BENCHMARKS.md).
