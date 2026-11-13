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
- **Memory** (`tools/e2e/soak.wac`): 2400 blocks of 300–500 new slots each under `wac --max-heap 256m` — the store
  grew to 411 MB, resident memory settled at 312–331 MB. Before this branch's fixes the same run grew ~0.75 MB a
  block.
- **Crashes** (`tools/e2e/crash.wac`): a store node killed with SIGKILL at random points while importing — 110
  kills over three runs, 47 before the block's commit was whole and 63 after — always came back to the uncrashed
  node's head, state root, slots and balances.
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

The first three are in the same 150 lines of `tree.wac` (leaves in memory, letting them go, commits); that code
has had the most bugs and the most new tests, and is where a reviewer's time is best spent.

## Risks

- **Not yet run against the real network.** Snap sync has only met geth on private devnets: never a public peer
  set, rate limits, peers that drop or lie, or a state the size of Hoodi's (tens of GB). Healing has met a pivot
  that ages out by our own simulation, because geth here kept serving old pivots.
- **No consensus client has driven it.** Every Engine API call in testing came from fixtures or our own test
  driver. A local Prysm or Lighthouse was blocked in this container; Hoodi will be the first.
- **Scale.** The largest store so far is 411 MB; Hoodi's will be tens of GB and mainnet's hundreds. The interior
  is kept in memory (~400 MB estimated at mainnet), and how the cache, the leaf budget and commit cost behave at
  that size is extrapolated from a 64-block trace, not measured.
- **A commit every block.** The store commits each block as it goes in (~0.1–0.2 s of writes and an fsync); the
  design's batching of commits over many blocks is not built. Fine for following the head; slow for a long
  catch-up.
- **Torn writes on a real power cut** are modelled (any subset of unsynced writes lost), not exercised: SIGKILL
  leaves the kernel's page cache intact.
- **Store format**: new, and changed once already (64 KB → 16 KB pages); there is no migration, and none is
  needed while no store exists anywhere that matters.
- **wac workarounds**: a field-table limit in the checker (wac 0468d; `Engine`'s new fields grouped into one) and
  the deno-only oracle tests (abi, mpt, ssz) not runnable in this container.

## Not tested at all

A real consensus client; Hoodi; mainnet's size; days of uptime; a full disk; another client snap-syncing from
wacuum (the server is tested against our own client only); deep reorgs on the store beyond what the fixtures
contain.

## Recommendation

Merge. `--store` is opt-in. Without it the node passes the same fixtures as before; its changes there are that it
keeps the last 32 built payloads rather than all, and asks each peer in turn for blocks it lacks. The next
step — Hoodi — needs this code on the machine whichever branch it comes from, and the risks above are the ones
only Hoodi can retire. Merging now keeps the branch from drifting while that happens.
