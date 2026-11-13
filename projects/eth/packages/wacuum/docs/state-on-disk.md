# State on disk, snap sync, and what a consensus client drives (design, 2026-11-13)

Path B of `docs/mainnet.md`: wacuum joins mainnet by snap-syncing a recent state, then a consensus client
drives it through the Engine API it already has. This note decides how the state lives on disk, how a
synchronous EVM reads it, how it survives a crash, and how snap fills it. It is short on purpose: each
section names a decision and the measurement or constraint behind it, and the code is where the rest goes.

## What the host gives, measured

wac has no database and no bindings to one. It has `Files.openRandom` → `RandomFile` with `readAt`,
`writeAt`, `size`, `truncate`, `sync` and `close`, each an asynchronous request to the host. On the native V8
host, in this container (file in the page cache, so this is the host and not the disk):

| call | cost |
| --- | --- |
| `readAt` 16 B | 54 µs |
| `readAt` 4 KB | 64–72 µs |
| `readAt` 64 KB | 129 µs |
| 64 reads in flight at once | no faster than one at a time |

So **a call costs ~55 µs whatever it carries, plus ~1 µs a KB**, and the host serves them one after another.
NVMe random reads are 10–100 µs, so the host's overhead, not the disk, sets the price, and the design's first
rule is: *few calls, each carrying a lot*. (Asked of wac: a cheaper call, and a vectored read.)

The heap is the second constraint: the V8 host stopped at ~1.4 GB, and there is no flag to move it (asked
of wac). Everything kept in memory — caches, the in-flight blocks' changes, indexes — fits in about 1 GB.

## The store: one file, a copy-on-write B+tree with big pages

**Why a B+tree and not an LSM.** Reads decide it. An EVM read is a point lookup, often of a key that does
not exist (an empty slot), and a block needs a few thousand of them. A B+tree with its interior in memory
answers any lookup, present or absent, in **one** `readAt`. An LSM answers a present key in one read per
level until found and an absent one in one read per level (five or so) unless bloom filters are kept — at
10 bits a key, 2 GB of them for mainnet, which is more than the heap. Writes favour an LSM, but the writes
here can be batched (below), and snap's bulk load arrives sorted, which a B+tree builds bottom-up in one
sequential pass.

- **Pages of 64 KB.** At ~55 µs a call, a 64 KB leaf costs twice a 4 KB one and holds sixteen times as much.
  Mainnet's ~150 GB of flat state is ~2.5 M leaves; their separators — the interior — are ~100 MB, kept in
  memory (and rebuilt from the file on start). A lookup is then exactly one leaf read.
- **Keys are snap's**: an account at `0x00 ‖ keccak(address)`, a slot at `0x01 ‖ keccak(address) ‖
  keccak(slot)`, a code at `0x02 ‖ codeHash`, a trie node at `0x03 ‖ owner ‖ path` (owner empty for the
  account trie, `keccak(address)` for a storage trie). Hashed keys are what snap delivers and what the trie
  is ordered by, so ranges of the store and ranges of the trie are the same thing.
- **Values**: an account in snap's "slim" RLP (nonce, balance, storage root, code hash, with the empty root
  and empty code hash elided); a slot as its RLP; a trie node as its RLP; a code as its bytes.
- **Copy-on-write, two meta pages.** A commit writes every changed page to free space, `sync`s, then writes
  the meta page (root page, free list, the block it holds the state of, its state root, a checksum) into
  the slot not used last, and `sync`s again. A crash before the second `sync` leaves the previous meta,
  which still points at untouched pages: the store is always one whole committed state. This is LMDB's
  scheme, and it needs no write-ahead log of its own.
- **Free pages** are those the previous commit's tree no longer reaches; the free list is part of the meta's
  commit, so it is crash-safe the same way.

## Batching writes: diff layers in memory, flushed every N blocks

Writing each block's changes straight to the tree would rewrite ~1500 leaves a block (one per changed key,
since hashed keys scatter): ~1500 × (55 + 64) µs and 96 MB a block. Instead, as geth does, **each block's
changes stay in memory as a layer** (`World`'s `ChangeSet`s are exactly this today), the newest on top, and
every **N = 128** finalized blocks the bottom layers are merged and flushed as one commit. Hot keys are
written once per flush rather than once per block, and 128 blocks' changes are ~100–200 MB of heap.

- **Reads** look through the layers top-down (a map lookup each), then the cache, then the tree.
- **Reorgs** below the flushed block cannot happen: only finalized blocks are flushed, and the layers above
  are what a reorg undoes — `World.undo` already does it.
- **The cache**: an LRU of accounts and slots read from the tree, bounded by bytes (~300 MB).

## Crash safety and resume: the block log already exists

wacuum already appends every imported block and fork choice to a log before acknowledging it, and replays
the log on start. With the store, **the store's meta names the block it holds**, and a restart opens the
store and replays the log from the block after it — the layers are rebuilt by re-executing at most N
blocks. The whole-state snapshot every 1024 blocks (`--snapshot-every`) is retired: the store is the
snapshot. The log is truncated below the flushed block.

## The state root: a trie by path, in the same tree

The header's state root is checked every block, so the root must be updatable from what changed. Trie nodes
are stored **by path** (geth's path scheme, "PBSS"): node `0x03 ‖ owner ‖ path`, one entry per path, so
updating the trie overwrites in place and never needs garbage collection of old nodes. A block's root:
for each changed key, the nodes on its path are read (upper levels of the account trie are always in the
cache; ~2 reads a key otherwise), the path is rehashed, and the new nodes go into the block's layer. Those
reads are the same keys every block in the head of the trie, so the cache absorbs most of them.

`LiveTrie` (`src/trie/live.wac`) already rehashes only dirty paths; it gains a node source the same way
`World` gained a `StateSource`.

## The EVM is synchronous; the disk is not

Every host read is asynchronous and the interpreter is a synchronous loop. Three layers, the first two
cheap and the third the guarantee:

1. **Before a block**: every transaction's sender, recipient, access list and the coinbase are read in one
   batch of (sorted, so neighbouring keys share leaves) reads.
2. **Speculation**: transactions are run once against the cache with misses noted rather than waited for —
   `replay.wac` does exactly this over the network today, and `World`'s `StateSource` is the hook — and the
   misses are read. Most of a block's reads are found in one or two such passes.
3. **Suspension**: an opcode that reads state (`SLOAD`, `SSTORE`'s read of the original value, `BALANCE`,
   the `EXTCODE*` family, the `CALL` family's target, `CREATE*`'s collision check, `SELFDESTRUCT`'s
   beneficiary) first asks whether its keys are in memory; if not, **before charging gas or changing
   anything**, the interpreter stops with the keys it needs and the program counter where it was. The
   caller awaits the reads and resumes; the opcode then runs as if nothing happened. This is possible
   because frames already live on the EVM's own stack rather than the host's, so stopping is returning and
   resuming is calling the loop again. Same for the transaction prologue (sender, recipient, delegation).

Layer 3 alone is correct; 1 and 2 make it fast. The `StateSource` hook stays as the boundary: a source that
can say "not yet" is all the EVM needs to know about the disk.

## Snap sync (snap/1)

1. **Pivot**: the consensus client's head less 64 blocks, from its first `forkchoiceUpdated`. Its header
   comes from peers; its state root is the target.
2. **Accounts**: `GetAccountRange` over sixteen slices of the hash space, from as many peers as answer, each
   answer's range proof checked against the pivot's root (`packages/mpt` verifies proofs already). Accounts
   arrive sorted; they are written to the store as they come and fed to a **stack trie** that emits the
   account trie's nodes by path, bottom-up, as soon as each subtree is complete.
3. **Storage**: for every account whose storage root is not empty, `GetStorageRanges`, batched for small
   storages, chunked for large ones, each trie built the same way under its owner.
4. **Code**: `GetByteCodes` for every distinct code hash.
5. **Healing**: the pivot moves while this runs, so the result is a patchwork of several states. From the
   new pivot's root, the trie is walked; a node missing or different on disk is fetched with `GetTrieNodes`
   by path, and its leaves replace the flat entries under it. When the walk finds nothing to fetch, the
   store holds the pivot's state exactly.
6. **Then**: blocks from the pivot to the head by the full sync that exists (`src/p2p/` backfill), and the
   consensus client takes over through the Engine API.

Mainnet's snap download is ~100–150 GB at the 50 Mbps assumed: 5–7 hours of transfer; geth's experience is
a day with healing. wacuum's own costs: ~2.5 M leaves written sequentially in large writes (~minutes of
calls), and ~1.5 billion keccaks for the trie (~1 µs each in wac: ~25 minutes).

## Order of work, and what each is checked by

1. **The store** (`src/store/`): pages, the B+tree, commits, the meta pair, the free list. Checked by a
   model test (random operations against a `Map`, with crashes simulated by dropping writes after a point)
   and by reopening.
2. **The store behind `World`**: the `StateSource` reads it, flushes write the layers. Checked by the state
   and blockchain fixtures run with every account and slot behind the store (a "cold" mode), which must
   stay all green, and by restarts in the engine tests.
3. **The trie by path** behind `LiveTrie`, and the state root from it. Same fixtures.
4. **Suspension** in the interpreter. Same fixtures, cold, with a source that says "not yet" to every first
   read.
5. **snap/1**: messages, range proofs, the stack trie, healing. Checked against geth on a devnet
   (`tools/e2e/devnet.wac` gains a snap-synced node), then a public testnet.
6. **Hoodi end to end**, then mainnet. Hoodi is young and its state is small; it needs a machine with p2p
   (this container has HTTPS out only), so the provisioned node is wanted from step 5 on.

## The node on the store (as built, superseding "diff layers" above where they differ)

What was built first, in order, each with the cold fixture runs as its check: the B+tree (`src/store/tree.wac`),
the state in it under snap's keys (`src/store/state.wac`), the tries by path (`src/trie/pathtrie.wac`), and a
block run a step at a time with only a step that missed run again (`BodyRun`, `src/store/exec.wac`) — the
second layer of reads above; the third (stopping at the opcode) waits until measurements say it is needed.

For the engine, a simpler arrangement than flushing only finalized blocks: **the store holds the state of
the block the engine is at.** A block imported is committed as soon as its root matches its header; moving
across a reorg commits the departing blocks' before-states and the arriving blocks' after-states, which the
engine's change sets already hold. Then there is never state in memory that the store does not have, a
restart needs only the block log after the block the store's meta names, and the `World` is a cache over
the store rather than the state. A commit a block (~0.2 s of host requests and an `fsync`) fits a 12 s slot;
batching commits during a long catch-up is the optimisation, if measurements ask for it. One limit,
recorded rather than solved: undoing a block that deleted an account with storage needs every slot it
had, and only the slots read are noted — after Cancun, SELFDESTRUCT deletes only what the same transaction
created, so no such block exists on a chain this runs.

The engine stays synchronous — its JSON-RPC handlers, tests and fixture runners call it so — and gains
`prepare(method, params)`, which the server awaits before `call`: in store mode it does the asynchronous
part (moving the store to the right block, running a payload with step retries and computing its root from
the tries, reading what a state query will read), so that `call` finds everything in memory.

## Decisions for Andrew

- **wac host asks** (filed when this starts): the per-call cost of host I/O (~55 µs), a vectored read, and
  a heap limit above ~1.4 GB. None blocks the design; each makes it faster or roomier.
- **The node is needed for step 5's public-testnet test**, earlier than mainnet: this container cannot open
  p2p connections. A devnet against geth covers snap until then.
