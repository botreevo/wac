# Merging `state-store` — what it changes, how it is tested, what is not (2026-11-13)

For Andrew, deciding whether `state-store` goes into master. It is 53 commits ahead of master and none behind,
so it fast-forwards. Outside `packages/wacuum` it changes three lines: the wac pin (`wac.lock`), the unit-test
task's grant (`tasks.json5`), and one line of the devnet.

## What it is

Path B of `docs/mainnet.md`: wacuum keeps its state on disk instead of in memory, gets that state by snap sync
instead of replaying from genesis, and follows the head as a consensus client drives it. Before this branch the
node held the whole state in the V8 heap (~1.4 KB an account) and could only sync from genesis; mainnet was out
of reach on both counts. The design documents are `docs/state-on-disk.md` and `docs/state-cache.md`; Hoodi is
`docs/hoodi.md` and `deploy/hoodi/`.

| area | what | where |
| --- | --- | --- |
| store | one file, a copy-on-write B+tree of 16 KB pages, crash-safe two-meta commits, interior in memory, leaves by a 64 MB budget, a read/write gate | `src/store/tree.wac` |
| cache | raw entries (and absences) between blocks, 256 MB by default, CLOCK, written through by commits | `src/store/cache.wac` |
| state | accounts, slots, codes and trie nodes under snap's keys; the tries by path, rehashing only what changed | `src/store/state.wac`, `src/trie/pathtrie.wac` |
| execution | reads where the EVM misses (`getNow`), so no step runs twice | `src/store/exec.wac`, `StateDb.readsNow` |
| engine | `--store`: the store holds the state of the block the engine is at; reorgs commit back and forth; restart from the store plus the block log | `src/engine/engine.wac`, `cmd/wacuum.wac` |
| history | every block's RLP and receipts in the store; old blocks answered from it; 256 finalized blocks held in memory | `src/store/blocks.wac`, `receipts.wac` |
| snap/1 | client (accounts, storage, codes, from every peer at once, range proofs checked), healing by GetTrieNodes as the pivot moves, and a server answering from one consistent state | `src/p2p/snap.wac`, `src/p2p/node.wac` |
| RPC | `eth_call`, `eth_getProof` and the rest on the store; `wacuum_sizes` (what it holds between blocks) | `src/engine/engine.wac` |
| deploy | Hoodi: geth reference + wacuum, each driven by Lighthouse; a compare tool | `deploy/hoodi/`, `tools/hoodi/` |
| tools | mainnet replay and its trace, the cache simulator, the host and memory measurements | `tools/mainnet/`, `tools/measure/` |

## How it is tested

- **Fixtures, every fork** (execution-spec-tests v5.4.0), in memory: Cancun, Prague and Osaka — state, block,
  engine and block-building suites — and the six fork transitions to BPO4: 0 failures (Cancun state 16 847,
  Osaka engine 21 577, …; `dist/all-fixtures.txt`). On the store (`COLD=1`, every account and slot read from a
  store, the engine moving the store across invalid payloads): 0 failures too — Cancun block and engine 17 685 each, Prague 20 859 and 20 878, Osaka 21 558 and 21 577.
- **Unit tests**, 24 files, among them: the store against a map across commits and reopenings; a commit cut at
  every one of its writes, with none, all and six random subsets of the unsynced writes kept, coming back as
  exactly the state before or after; a leaf rewritten by a commit not let go before its page is written (a gated
  disk); leaves held within their bound when only commits load them; a 64 KB store refused; the cache against a
  store without one; snap between two stores, from three peers, and healing a pivot that moves at four points;
  snap answers that stay consistent while six blocks commit under them.
- **End to end, against geth 1.17**: snap sync from one and from three geths, plain and with the pivot made to
  age out and the state healed (`tools/e2e/snap.wac`), every account checked against geth, `eth_getProof` node
  for node; the JSON-RPC a wallet uses, on the store, with one block of history in memory and the rest read from
  disk, across a restart (`rpc.wac --store`); the devnet suite.
- **Memory** (`tools/e2e/soak.wac`): 2400 blocks of 300–500 new slots each under `wac --max-heap 256m`, commits
  batched 64 blocks at a time — the store grew to 714 MB, resident memory stayed at 269–319 MB. Before this branch's
  fixes the same run grew ~0.75 MB a block.
- **Scale** (`tools/measure/scale.wac`): a synthetic store filled to 5 GB (as much as this container's disk
  allows with a margin) — 4.4M accounts and 438 contracts of 20 000 slots, in 219 snap-sized batches — probed
  every 500 MB with three blocks of 1 000 cold account reads and 500 writes each:

  | store | reads, ms | commit, ms | leaf reads a probe |
  | ---: | ---: | ---: | ---: |
  | 0.5 GB | 35 | 211 | 1 692 |
  | 1 GB | 46 | 268 | 1 955 |
  | 2 GB | 55 | 323 | 2 143 |
  | 4 GB | 56 | 393 | 2 313 |
  | 5 GB | 63 | 415 | 2 384 |

  Costs grow with the tree's depth, about logarithmically. The 5 GB store opens and works under `--max-heap 256m`
  (214 MB resident). Five mainnet blocks replayed on top of it: execution as on an empty store (1.36 s against
  1.24 s), the commit six times slower (2.8 s against 0.48 s, 15 506 page reads against 2 964), 42 Mgas/s against
  104 — a commit rewrites a leaf for nearly every key it touches, and on a big store those leaves are cold and
  apart. That is ~0.57 s a block, well inside a slot; it is the number to watch at Hoodi's size.

  Where a probe block's time goes at 5 GB (500 accounts written, one commit, file in the page cache): its reads
  ~50 ms; staging (the tries' new nodes and the root) ~125 ms, 1 229 leaf reads of which the host's part is ~26 ms
  and the rest hashing and encoding; the store's commit only 185 leaf reads but 2 171 page writes and two syncs.
  The host (`tools/measure/inflight.wac`, this VM's virtio disk): a 16 KB read from the page cache is ~21 us
  however many are in flight; from the disk, 448 us one at a time and 218 us with 256 in flight; a write 86 us
  alone and 25 us with 64 in flight; a sync ~85–90 ms whatever came before it. So a commit now sends its writes 64
  at a time and reads the leaves it will need 64 ahead (`Store.inFlight`, `Store.prefetch`): the commit went from
  311–339 ms to 262–264 ms, and what is left is mostly its two syncs — which batching (`--flush-every 64`, the
  default) pays once per 64 blocks rather than every block.

  Trie nodes were keyed by their path, depth first, which near the top puts siblings — and a node and its child —
  whole subtrees apart: a 500-account block wrote 1 + 16 + 219 + 461 leaves for depths 0–3 alone, one for every
  node. The top five levels are now keyed level by level (store format 4, `pathtrie.wac`'s `nodeKey`): those
  depths take 1 + 2 + 10 + 178 leaves, all leaves written per block ~1 900 → ~1 660, page writes 2 171 → 1 721,
  staging 113–150 → 90 ms, the store's commit 262 → 211 ms. Refilled to 5 GB the same way, the five mainnet blocks
  on top: commit 2.83 → 2.08 s, 42 → 48 Mgas/s. What is left is one leaf per account for its deep nodes (depth 5
  and below) and one for its entry.
- **Crashes** (`tools/e2e/crash.wac`): a store node killed with SIGKILL at random points while importing — 110
  kills over three runs, 47 before the block's commit was whole and 63 after — always came back to the uncrashed
  node's head, state root, slots and balances; and with commits batched, 40 kills flushing every 8 blocks and 40
  flushing every 64 (restarts replaying up to 62 blocks from the log), the same.
  With side chains in the stream (every tenth block preceded by one or two side blocks made the head and then
  reorged away, so kills land in reorgs and restarts must undo blocks they did not run): 51 runs of 200 blocks
  and 40 kills each on 9286bee and after — 39 flushing every block, 12 every 64 — 50 came back exactly; the one
  that did not was the harness (parallel runs taking one another's port as a node restarted; the ranges are now
  wide). The runs before found three bugs, each now with a unit test (`test/resume_test.wac`): a store a block
  ahead of the chain log stuck SYNCING for good; no undo across a restart, so any reorg below the store's block
  after one stuck; and a fork choice for a side chain finality had ruled out refusing the log on replay.
- **Mainnet blocks**: five consecutive blocks replayed on the store match their headers but for the state root
  (the store holds only what they read), at ~100 Mgas/s; 64 blocks traced for the cache's design.
- **Hoodi, without the machine**: wacuum computes Hoodi's genesis hash, geth `--hoodi` accepts its handshake
  (the fork ID, with Osaka and both BPO forks), the deploy script starts it beside a local geth.

## Bugs found and fixed on the way, worth knowing about

Each has a test that fails without its fix.

- A leaf read could be let go by a stale queue entry just after it was attached, and a commit to it was lost from
  the file.
- A read during a commit could let go a leaf the commit had rewritten before its page was written.
- With every read served from memory, leaves were never let go at all (the store's queue grew without bound).
- A snap answer could mix two states when a block committed during it.
- The node kept every account and slot it had read, every payload it built, and every block's history, in memory.
- After a snap sync the node fetched missing blocks from the same peer every time, and never got them if that
  peer lacked them.
- A store a block ahead of the chain log (a stop between the commit and the log's write) left the node SYNCING for
  good; and with no change sets across a restart, so did any reorg below the store's block after one. Now the
  store keeps each unfinalized block's undo record, and a restart adopts its own block from the store first.
- A fork choice in the log for a side chain finality had ruled out made replay refuse the log: the node did not
  start.
- Payload statuses named a hash with a leading zero nibble shortened; consensus clients cannot read it, so one block
  in 16 failed and a follower stopped for good.

The first three are in the same 150 lines of `tree.wac` (leaves in memory, letting them go, commits); that code
has had the most bugs and the most new tests, and is where a reviewer's time is best spent.

## Risks

- **Not yet run against the real network.** Snap sync has only met geth on private devnets: never a public peer
  set, rate limits, peers that drop or lie, or a state the size of Hoodi's (tens of GB). Healing has met a pivot
  that ages out by our own simulation, because geth here kept serving old pivots.
- **Two consensus clients, on private chains** (2026-11-14), every fork through Fulu/Osaka at genesis, 2 s slots, 64
  validators, geth beside wacuum judging every block by itself under its own beacon node:
  - `tools/e2e/cl.wac` — Prysm 7.3.1 drives wacuum as the builder: 127 blocks in 128 slots, transfers and a blob
    block in them, geth with the same blocks, wacuum killed and started again going on, epoch 2 finalized alike.
  - `tools/e2e/cllh.wac` — the same under Lighthouse 8.3.3, Hoodi's deploy's client: 129 blocks in 130 slots.
  - `tools/e2e/clfollow.wac` — Hoodi's situation: geth builds, wacuum only follows under its own Prysm (gossip,
    newPayload), killed and caught up, takes geth's blob block, agrees on finality; and a second wacuum started
    empty under a checkpoint-synced beacon node snap-syncs from geth to the head and follows, its balance geth's.
  Found on the way: payload statuses gave a hash with a leading zero nibble shortened, which Prysm cannot read — one
  block in 16 failed, and a follower stopped for good (fixed, with a test). Not covered: a public network's peers
  and latency, real (non-zero) blobs' KZG work, Prysm and Lighthouse together (they do not peer here: Lighthouse
  rejects Prysm's custody group count of 0).
- **Scale.** The largest store so far is 5 GB, synthetic; Hoodi's will be tens of GB and mainnet's hundreds. The
  interior is kept in memory (~400 MB estimated at mainnet). Commit cost grows with the store (above); beyond 5 GB
  it is extrapolated, not measured.
- **Commits batched over 64 blocks** (built after this note was first written): a stop of any kind replays up to
  64 blocks from the log on restart (wac programs cannot catch signals, so every stop is a crash); the overlay
  holding those blocks' changes is ~2 MB a block at mainnet's rate, bounded by a 64 MB flush.
- **Torn writes on a real power cut** are modelled (any subset of unsynced writes lost), not exercised: SIGKILL
  leaves the kernel's page cache intact.
- **Store format**: new, and changed once already (64 KB → 16 KB pages); there is no migration, and none is
  needed while no store exists anywhere that matters.
- **wac**: pinned at 424e0273b, which fixes the checker's field-table limit (0468d) that `Engine`'s new fields
  first ran into; they stay grouped in `Persisting`, which reads well as it is. The deno-only oracle tests (abi,
  mpt, ssz) are not runnable in this container.

## Not tested at all

Hoodi; mainnet's size; days of uptime (the longest consensus-client run is ~4 minutes of chain, the 2400-block soak
~9 minutes); a full disk; another client snap-syncing from wacuum (the server is tested against our own client
only); real blobs' KZG work; Prysm and Lighthouse on one chain.

## Where it stands, and what is next (2026-11-14, wound down)

Everything above is on `state-store`, pushed; nothing went to master. Next, in order:

1. **The follower soak** — `tools/e2e/clsoak.wac`: geth builds under Lighthouse, wacuum follows on a store (flush 64,
   heap capped) under its own Lighthouse, with transfers, a blob block every ten minutes, a kill every 20–40
   minutes, and `tools/hoodi/compare.wac` every minute. A 6-minute run passed (lag 0, 69 MB resident under 512m);
   the 3-hour run was stopped in its setup when work wound down. Run it for hours before Hoodi:
   `wac run --allow-read --allow-write --allow-net --allow-run tools/e2e/clsoak.wac -- GETH PRYSM_BIN LIGHTHOUSE 180 512m`.
2. **Hoodi** — `docs/hoodi.md`, with what the consensus-client tests taught folded in: Lighthouse 8.3.3 the version
   tested; a wacuum at or after `ac19578`; restarts fetch missed blocks from the local geth `run-wacuum.sh` peers
   it with; Lighthouse's log is where an execution-engine error shows. The units needed no change.
3. **Open items**: deliberate reorgs under a consensus client (one validator client holding every key gives no way
   to fork; reorgs after restarts are covered by unit tests and `crash.wac`'s side chains); commit cost on a big
   store (~0.57 s a block at 5 GB before the layout work, 1.56 s for five mainnet blocks after; the two syncs a
   commit are most of what is left — batching pays them once per 64 blocks); the store's scale beyond 5 GB.

## Recommendation

Merge. `--store` is opt-in. Without it the node passes the same fixtures as before; its changes there are that it
keeps the last 32 built payloads rather than all, and asks each peer in turn for blocks it lacks. The next
step — Hoodi — needs this code on the machine whichever branch it comes from, and the risks above are the ones
only Hoodi can retire. Merging now keeps the branch from drifting while that happens.
