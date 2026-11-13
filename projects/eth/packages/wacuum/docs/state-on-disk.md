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
batching commits during a long catch-up is the optimisation, if measurements ask for it.

**Since built** (`Store.stage`, `flush`; `--flush-every`, 64 by default): a block's commit is staged in an
overlay in the store, which every read looks through first (point reads at once; ranges merged in key order,
and the hot paths — codes, receipts, blocks — read their chunks point by point instead), and the overlay is
written as one commit every 64 blocks or 64 MB of keys and values. The store still reads as holding the state of
the block the engine is at, so nothing above it changed. A crash, or any stop (wac has no signal handlers, so a
stop is a crash), loses the overlay: the file is at the last flush, whose bytes name its block, and the block
log replays what came after — up to 64 blocks. `tools/e2e/crash.wac -- 200 40 64`: 40 kills, restarts replaying
up to 62 blocks each, the same head, root, slots and balances as a node never killed. Writes a block fall from
~5190 keys to ~1950 at 64 (the 64-block mainnet trace). One limit,
recorded rather than solved: undoing a block that deleted an account with storage needs every slot it
had, and only the slots read are noted — after Cancun, SELFDESTRUCT deletes only what the same transaction
created, so no such block exists on a chain this runs.

The engine stays synchronous — its JSON-RPC handlers, tests and fixture runners call it so — and gains
`prepare(method, params)`, which the server awaits before `call`: in store mode it does the asynchronous
part (moving the store to the right block, running a payload with step retries and computing its root from
the tries, reading what a state query will read), so that `call` finds everything in memory.

### Measured: mainnet blocks on the store (2026-11-13)

`tools/mainnet/replay.sh` then `replay.wac --store FILE` on blocks 26,404,100–104 (1131 transactions, 178 Mgas):
the state they read (2827 accounts, 1080 storages) written into a store in a file, then each block imported
as the node imports it — a fresh cache over the store, a step at a time, the root from the stored tries, a
commit a block:

| | time | Mgas/s |
| --- | ---: | ---: |
| all in memory, senders recovered | 869 ms | 205 |
| on the store: executing | 10,494 ms | |
| on the store: committing (roots and writes) | 407 ms | |
| on the store, together | 10,901 ms | 16 |

Committing is cheap. Executing is not, and the steps say why: 9784 steps, 8643 of them run again — about
7.6 reruns a transaction, because a transaction whose reads depend on what it read (a swap reading a pool,
then the slots the pool names) finds its misses one layer at a time, and each layer is a rerun from the
transaction's start. 16 Mgas/s follows a head that needs ~5; catching up at it would take months.

**Then: reads waited for where they are asked.** A host ticket can be waited on synchronously — `wait()`
drives the host's own ticket to its answer (no `async` frame around it, so 0473w's leak does not apply;
30,000 such reads of 64 KB stayed at 63 MB) — at ~63 µs a call plus ~4 µs a KB. So a miss is read from the
store at the opcode that misses (`Disk.readNow`, `Store.getNow`, `StateDb.readsNow`), the EVM never misses,
and no step runs twice — the third layer, without making the interpreter resumable:

| the same five blocks | time | Mgas/s |
| --- | ---: | ---: |
| on the store, misses read where they happen, every leaf read from the file | 1123 ms executing, 376 ms committing | **119** |

1141 steps, none again; 455 leaf reads (this state is small: at mainnet scale expect a leaf read for most
keys a block touches, ~0.3 ms each at 64 KB, so nearer 40–50 Mgas/s until a leaf cache catches the hot
ones — to be measured on the machine). Every cold fixture suite passes with it; the asynchronous
miss-and-rerun path (`fetch`, `BodyRun.clean`, `World.unask`/`forgetSince`) is now unused by default, and
goes once it is clear no host needs it.

## Crash windows: the store, the chain log and fork choice (2026-11-13)

Three things are written, in this order, and a stop (every stop is a crash) can fall between any two:

1. **the store's commit** — at `--flush-every 1` in `prepareBlock` as a block imports, and in `moveToAsync` for
   each block a reorg crosses; at 64, those are staged and only every 64th block's (or 64 MB's) is a commit. The
   commit's own bytes name the block whose state it holds, and the block's RLP and receipts are in the same commit
   (`Engine.withBlock`);
2. **the chain log's block record** — pushed by `call` after the commit, written before the answer goes out;
3. **the chain log's fork-choice record** (head, safe, finalized) — the same, for `forkchoiceUpdated`.

Head, safe and finalized live only in the log. Change sets — what lets the store move to a parent's state —
live only in memory: a restart rebuilds them for the blocks it runs again from the log, and has none for a
block at or below the store's (`replay` adopts those without running them).

| stop falls | the store holds | the log ends at | on restart | checked by |
| --- | --- | --- | --- | --- |
| before (1), any flush | the block before | the block before | replay; the payload is given again and imports | crash.wac, every kill "not in the store" |
| between (1) and (2), flush 1 | block N | N − 1 | **was stuck**: no block for the store's state, every payload SYNCING. Now `adoptStored` reads N from the store, adopts it and logs it; the payload given again is VALID | `test/resume_test.wac`; crash.wac (6 of 15 runs before the fix) |
| between (1) and (2), flush 64, at a flush | block N | N − 1 | the same as flush 1 (a flush is a commit at N) | `adoptStored`; crash.wac at 64 has not landed a kill there yet |
| between (1) and (2), flush 64, not at a flush | the last flush, F < N | N − 1 | replay runs F + 1 … N − 1 from the log; N is given again | crash.wac at 64 (replays of up to 62 blocks) |
| between (2) and (3), no reorg | N | block N, head N − 1 | head N − 1, the store at N; the fork choice given again moves the head, and the store need not move | crash.wac, every kill "in the store" |
| between (1) and (3) of a **reorg**, flush 1 | a block X on the way from the old head to the new | the old head | blocks at or below X are adopted with no change set, so the store cannot leave X's chain; the fork choice given again works only when the new head's chain runs through X | **not tested, and not recovered in general** |
| after (3) | the head | the head | — | — |

**And not only crashes: a reorg below the store's block, after any restart.** The same missing change sets mean
that after a clean restart at flush 1 — the store at the head — a payload whose parent is below the head, a
one-block reorg, is SYNCING, and stays so: the store cannot go back to the parent's state. Checked by hand
(three blocks, a clean restart, the sibling of the head: SYNCING; with no restart: VALID). At flush 64 the
same holds for a reorg whose branch point is below the last flush. One-block reorgs are routine on a live
chain, so a node restarted at the wrong moment stops following it. This blocks Hoodi as much as the crash did.

What would fix it, both keeping "the store reads as the state of the block the engine is at":

- **Commit only finalized blocks**: the overlay holds everything above finality (64–95 blocks on mainnet,
  ~2 MB a block, so ~130–190 MB; more while finality stalls, bounded by a forced flush that brings the gap
  back only then), and a restart replays from the finalized block with change sets for every block a reorg can
  reach. The design this document started from; the overlay has to flush a prefix (up to finality), not all.
- **Keep undo records in the store**: each block's commit also writes its change set (before and after values)
  under its hash, pruned once the block is finalized; a restart loads them for the blocks between finality and
  the store's block, so the store can move back. Costs a block's changed values written a second time (not
  measured), but no larger overlay and no longer replay.

## Decisions for Andrew

- **wac host asks** (filed when this starts): the per-call cost of host I/O (~55 µs), a vectored read, and
  a heap limit above ~1.4 GB. None blocks the design; each makes it faster or roomier.
- **The node is needed for step 5's public-testnet test**, earlier than mainnet: this container cannot open
  p2p connections. A devnet against geth covers snap until then.
