# lightclient — the Ethereum Altair light client sync protocol

A light client follows the beacon chain without downloading it. It holds a sync committee it
trusts, and each update carries a header, that committee's signature over it, and Merkle branches
proving the header's state contains the *next* committee and a finalized checkpoint. Believing one
update is a signature check and two branch checks; believing a *chain* of them is the
sync-committee period rules, which are what stop a client being walked onto a fork.

This package is those rules in wac. `src/store.wac` is the store and the update logic, function for
function as the spec has them; `src/domain.wac` is the signing-domain arithmetic they rest on. The
layouts and the Merkle proofs come from [`ssz`](../ssz/README.md), the signature verification from
wac's `bls` (`packages/bls` in wac).

```sh
deno test -A packages/lightclient/test/sync_wac.test.ts   # Ethereum's four sync cases, step by step
```

**The Altair sync protocol works.** All four of Ethereum's `light_client/sync` cases run
step by step — nineteen steps, sixteen real sync-committee signatures, every Merkle branch — and the
store's `finalized_header` and `optimistic_header` match the vectors' checks after each one. Filed as
wac-mono **0064**, now closed.

| | state |
| --- | --- |
| `compute_fork_data_root`, `compute_fork_digest` | **done** — checked against the vectors' `meta.store_fork_digest` |
| `compute_domain`, `compute_signing_root` | **done** |
| verifying a sync aggregate | **done** — all 16 updates in Ethereum's `light_client/sync` cases |
| `LightClientStore`, `initialize_light_client_store` | **done** |
| `validate_light_client_update` | **done** |
| `apply_light_client_update`, `process_light_client_update` | **done** |
| `is_better_update`, `process_light_client_store_force_update` | **done** |
| the sync-committee period rules | **done** |
| post-Altair headers: Capella–Fulu execution branches, Gloas's block-hash header | **done** — `src/header.wac`, below |
| mainnet fork schedule and versions | **done** — `ssz/src/forks.wac` (Gloas unscheduled upstream) |
| a fork-aware store (layout, gindices and fork version by fork) | **done** — `light_client_sync` for Capella, Deneb, Electra and Fulu: 40 steps |
| a store crossing a fork (`upgrade_lc_store_to_*`, the `*_store_with_legacy_data` vectors) | **not started** |
| a live beacon API | **not started** — 0066 |

## What the vectors cannot check, and what stands in for it

Every `process_update` step in Ethereum's sync vectors is a *valid* update: the suite is a liveness
test, and it says nothing about what a client refuses. A `validateUpdate` that returned `true`
unconditionally passes all nineteen steps, because the headers being checked come out of the update
rather than out of the check.

So the negatives are built here by corrupting real data, one field at a time, and each one was
confirmed to fail against a deliberately broken client before being kept:

| plant | what it would otherwise hide |
| --- | --- |
| a bit in the 96-byte signature | the BLS check |
| the finalized header's `body_root` or `state_root`, or a finality branch node | the finality branch — **the signature does not cover these bytes** |
| a `next_sync_committee` key or a branch node | the committee branch |
| a bootstrap committee key or branch node | the whole root of trust |
| `signature_slot == attested_slot` | the one strict slot relation |
| all 32 participation bits cleared | an empty aggregate verifying vacuously |

Two checks resisted this and are pinned directly instead, because every vector update is signed by
almost the whole committee: `>= 2/3` and `>= 1/3` accept exactly the same set, and a safety threshold
of `max/2` and of zero behave identically. Weakening either is invisible to the vectors. They are the
security boundary of the protocol, so `hasSupermajority` is a named function with its own boundary
test at 21 and 22 of 32.

A third group — the signature-period window, `MIN_SYNC_COMMITTEE_PARTICIPANTS`, and
`attested_slot >= finalized_slot` — cannot be observed from outside at all: each is subsumed by a
cryptographic check further down. `src/store.wac` names them as such rather than leaving a reader to
assume they are tested.

## What one verified signature actually proves

Checking a single update exercises, in order: SSZ field extraction from a `LightClientUpdate`,
merkleization of the beacon header it names, the fork data root, the domain, the signing root, the
sync-committee bit selection, and BLS `FastAggregateVerify` over the participating keys. A fault
anywhere in that chain gives a signature that does not verify, so it is a strong statement about all
of it at once — `packages/bls` and `packages/ssz` included.

All sixteen updates across the four vendored cases verify.

## The domain is the replay protection, and it is tested as such

A sync-committee signature is not over the block header. It is over
`hash_tree_root(SigningData(header_root, domain))`, and the domain mixes in the fork version and the
genesis validators root. The same header signed on another chain, or across a fork boundary, has a
different signing root.

Every positive test uses the right domain, so nothing in them would notice if the domain were ignored.
The negatives are therefore explicit: the same signature must **fail** under mainnet's Altair fork
version instead of minimal's, under a genesis validators root with one bit flipped, and over a
different header root.

`meta.store_fork_digest` in each vector is the first four bytes of exactly this fork data root, which
pins the fork version *and* the `ForkData` merkleization — including that `Version` is four bytes
left-aligned in a 32-byte chunk. Minimal Altair's `0x01000001` reproduces the vectors' `0x15cfa0a7`.

## Which committee signs, and why the test accumulates them

The spec picks `current_sync_committee` or `next_sync_committee` by comparing the update's signature
period with the store's. That rule belongs to the client, which does not exist yet, so the test stands
in for it with the store's actual behaviour: start with the bootstrap's committee and accumulate each
one an update supplies.

That is necessary rather than tidy. Three of the sixteen updates carry an **all-zero**
`next_sync_committee` — their filenames end `_x` — and are signed by a committee an earlier update
supplied. Trying only the bootstrap's and the update's own fails those, which is how this was found.

## Configuration

Minimal, because Ethereum's sync-protocol vectors exist only for it: `SYNC_COMMITTEE_SIZE` is 32
rather than 512, and Altair's fork version is `0x01000001` rather than `0x01000000`. Both mainnet and
minimal versions are exported; `packages/ssz`'s descriptor table takes the committee size as a
parameter for the same reason.

## After Altair (2026-11-10)

Read from `consensus-specs` at `0393013` (2026-11-09). What changes for a light client, fork by fork:

| fork | header | state branches | execution |
| --- | --- | --- | --- |
| Capella | gains `execution` (ExecutionPayloadHeader, 15 fields) and `execution_branch` | unchanged (105, 54/55) | payload root at body gindex 25, depth 4 |
| Deneb | payload header gains two blob-gas fields (17) | unchanged | unchanged |
| Electra | unchanged | BeaconState grew: 169, 86/87 (depths 7, 6) | unchanged |
| Fulu | **no light-client change** (there is no `specs/fulu/light-client`) | — | — |
| Gloas | `execution` removed; `execution_block_hash` only (EIP-7732) | EIP-7688: 735, 2945/2946 (depths 9, 11) | block hash at gindex 2856, the bid's `parent_block_hash` |
| Heze | no light-client change | — | — |

**The consequence that matters for anything reading state by proof:** from Gloas on, a header does not contain an
execution state root at all. It proves a block hash, and that hash is the *parent* execution block's (in Gloas the
payload arrives after its beacon block). So the state root comes from that block's RLP header, fetched from anyone and
checked by `keccak256(rlp) == block_hash` (`ethrpc`'s `headerOf` does exactly this), and it is one slot older than the beacon header proving it. Since the block
hash is the one anchor every fork can give, `blockHashProof` gives it in Gloas's shape for Capella–Fulu headers as well
(the payload header's own branch to `block_hash`, gindex 412 or 812, joined to the execution branch), so one path can
follow the chain across the fork.

**What is checked, against what:**

- `ssz/src/forks.wac` is one descriptor table per fork. All 90 `ssz_static` cases (ExecutionPayloadHeader and the five
  light-client containers, mainnet, Capella to Gloas) merkleize to Ethereum's roots. This is the first real use of
  `container.wac`'s offsets: from Capella on, a header carries `extra_data`, a list.
- `src/header.wac` validates headers and reads the block hash and state root. Against `light_client_sync` for Capella,
  Deneb, Electra and Fulu (minimal): 60 real headers are valid, their Gloas-shaped block-hash proofs hold, 80 stated
  `execution_root`s match, and one byte changed in a payload's state root or in a branch is refused.
- **There are no Gloas vectors for this.** The release pinned here (`v1.6.0-beta.0`, the last before the
  consensus-spec-tests repository was archived) predates EIP-7732's light-client change: its Gloas containers are still
  Electra's, and `forks_test.wac` asserts exactly that. The Gloas path is written from the spec and is checked only
  through the shared block-hash construction above.

- `store.wac` takes its fork's layout, gindices and fork version (a `fork` field on the store; Altair's functions keep
  their names). Each fork's `light_client_sync` case runs through it step by step: 40 steps across Capella, Deneb,
  Electra and Fulu, the finalized and optimistic headers' beacon and execution roots agreeing at every step, and Altair's
  four cases unchanged. An Electra bootstrap read as Deneb's does not initialize.
- **One bug the vectors found:** from Capella on, the spec's `finalized_header == LightClientHeader()` is not "all zero
  bytes", because the default header serializes with two non-zero SSZ offsets in it. Testing for zeros refused every
  update without finality. `isEmptyHeader` is the real test.

**Still to do, in order:** a store that crosses forks (`upgrade_lc_store_to_*`, and the `*_store_with_legacy_data`
vectors); wiring a header's block hash into `ethrpc.headerOf(block, hash)`, which already re-encodes an execution header
and checks it against a given hash, so a Gloas block hash reaches a state root; mainnet's committee size and period length
in the store, which is minimal-only today; and a beacon API client (0066).
