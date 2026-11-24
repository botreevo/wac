# wac-eth

Ethereum in [wac](https://git.voltrevo.com/wac.git): the packages that verify what the chain says, an execution
client, and a devnet with its explorer, on one pin of wac.

Everything is a package, as in wac: some are libraries, and some also have commands, tools and deployments.

| | |
| --- | --- |
| `packages/rlp`, `packages/abi` | the encodings: RLP, and the contract ABI |
| `packages/mpt` | Merkle-Patricia proofs — a value, or its absence, against a state root |
| `packages/ethrpc` | asking a node, in the shapes `mpt` verifies; a node is trusted for availability, never for what it says |
| `packages/ens` | names, and resolving one by proof |
| [`packages/ipfs`](packages/ipfs/README.md) | objects under IPFS's `unixfs-v1-2025` profile: CIDs, UnixFS, DAG-CBOR, CAR, a checked store; reckon's object layer |
| `packages/ssz`, `packages/lightclient` | the beacon chain's layouts, and the sync-committee light client |
| [`packages/wacuum`](packages/wacuum/README.md) | an execution client: every execution-spec-tests fixture through Osaka, devp2p, sync, the Engine API |
| [`packages/wacuum-devnet`](packages/wacuum-devnet/README.md) | a devnet, its block explorer and its faucet, as one program; wacuum.voltrevo.com |
| [`packages/reckon`](packages/reckon/README.md) | attested derivations: objects pinned by hash, signed statements about how they were made and whether to use them, and a policy over both; the experiment behind design 0016 |
| [`design/`](design/README.md) | where this is going: [0003](design/system/0003-an-ethereum-centric-reference-distribution.md), the distribution it converges on, and [0016](design/system/0016-code-pinned-by-hash-and-trusted-by-attestation.md), code pinned by hash |

**Why one repository.** Until 2026-11-09 the packages lived in wac, and wacuum and the devnet in repositories of
their own, each pinning wac separately. A program using two of them carried two copies of wac's library — enough
to pass the compiler's 512-file limit — and values crossing between them (an engine's `JsonValue`) were the same
type only if somebody remembered to move both pins together. Here there is one `wac.lock`, so that is true by
construction, and a change to a package and its users is one commit.

What stays in wac is what is not Ethereum's: the language, `crypto` (keccak256 among it), `bls`, `json`, `codec`,
`http`, `wactest`. Those are imported from `"wac"`; this repository's own packages from `"@/lib.wac"` or by path.

## Getting started

Build the `wac` command from the commit `wac.lock` pins (a clone of wac, then `./bootstrap.sh --host nodejs`, or
without `--host` for the native one), put it on PATH, then here:

    sh tools/deps.sh        # the locked wac and web into wac's package cache, with git
    wac task test           # every unit test: the seven packages, reckon, the client, the devnet
    wac task check          # every file the manifest covers

`sh tools/use-local-wac.sh <a clone of wac>` fills the cache from a clone instead, without a network. Each
package with a command says in its README how to build and run it; wacuum's and the devnet's own `tasks.json5` still
work from inside them, and the root's `wacuum:`, `devnet:` and `reckon:` tasks run them from here.

## Using it from another project

    imports: { eth: { git: 'https://git.voltrevo.com/wac-eth.git', ref: 'master' } }

    import { mpt.storageAt, ethrpc.proofOfSlots, rlp.encode, wacuum.Engine } from "eth";

## History

The history of every file came with it: the packages' from wac (`git log --follow` crosses into it), wacuum's and
the devnet's from their repositories, merged under their directories. Those two repositories now say they moved.
