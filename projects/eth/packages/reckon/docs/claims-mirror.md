# Claims through mirrors

Admission (`claim admit`) decides from signed statements: derivations, endorsements, rejections, revocations. Until
now they came only from the local store's index. This is how they travel between people: published to a mirror,
fetched from any number of them, each one checked.

## The layout is the one there already

A mirror is a store directory as `saveIndex` writes it (src/graph.wac):

    claims/index          one `signed <cid>` or `recipe <cid>` per line
    ipfs/<cid>            each signed statement (DAG-CBOR) and recipe, and any other object, as a block

Served by any static web server it is also a trustless gateway for its blocks (`/ipfs/<cid>?format=raw`, which
`Store.http` asks for), so the same directory works on disk and over HTTP, and a real gateway can serve the blocks
of a mirror whose `claims/index` lives elsewhere.

## Publishing

`claim publish DIR` writes the local index into DIR: what DIR already holds, plus everything local, as one index.
It only adds. Publishing signs nothing: a statement is valid because of its signature, not because of who
published it, so anyone can republish anyone's statements, and a mirror can be a copy of another.

## Fetching

Every command that reads the index (`admit`, `origins`, `dependents`) takes `--mirror DIR` or
`--mirror http://HOST:PORT`, or `--mirror https://HOST[:PORT]` (through wac's `fetch`, TLS checked against the trust store and `SSL_CERT_FILE`, through the environment's proxy; a public trustless gateway such as https://trustless-gateway.link is one, serving blocks and no claims), repeatable. The index it uses is the local one together with each mirror's. Each mirror's
is loaded by `loadIndex`, which re-hashes every block and verifies every signature. What fails is left out and
reported on standard error, and the rest of that mirror is still used. Statements are kept by (signer, statement
id), so the same statement from two places is one.

## What a mirror can and cannot do

- **It cannot forge.** A statement it serves counts only if its signature verifies and the policy names its signer.
- **It can withhold.** A mirror can leave out a revocation or a rejection, and admission then decides without it.
  The union is the defence: a statement any one of your mirrors carries counts, so withholding needs every mirror.
  What must not be withheld goes on chain: revocations and rejections in the registry (`--rpc`), read by proof,
  where leaving one out is a failed proof rather than a silence.
- **It can serve a lot.** Each block is bounded by the HTTP client (64 MiB). A mirror can still list many
  statements. Nothing here limits how many yet.

## Not here

No discovery of mirrors (you name them), no signature on `claims/index` (its entries are content-addressed and
each is signed), no pruning of what a mirror holds, and nothing that keeps a fetched statement locally unless you
publish it to your own store.
