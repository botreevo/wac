# A cache in front of the store (design, 2026-11-13)

`docs/state-on-disk.md` put the state in a copy-on-write B+tree of 64 KB pages, read where the EVM misses,
and left open what stays in memory between blocks, so that a block at the head does not read most of what it
touches from the file. The working name was a *leaf cache*. This note measures what such a cache would catch
on mainnet's own blocks, and decides its unit, its size, how it stays in step with commits, and what it
replaces. **The answer is a cache of entries, not of leaves.** The tools are in `tools/measure/`, and each
number says which one made it.

## What there is today, and why it goes

Two things hold state in memory across blocks, and neither is bounded well:

- **`Store` keeps up to 4096 leaves** it has read (`maxLeaves`), oldest-loaded first out: 256 MB of 64 KB
  pages, each kept for the one or two keys a block wanted from it.
- **The node's `StateDb` keeps every account and slot it ever read**, decoded (`Known`, and a `U256` map per
  account, about 1.4 KB an account and 0.6 KB a slot as `docs/mainnet.md` measured), and the account trie's
  nodes it has opened. Nothing is dropped: at the head of mainnet it grows until the heap stops (~1.4 GB on
  the V8 host), within hours.

## What a read and an entry cost

`tools/measure/reads.wac`, 2000 reads of each size at random offsets in a 1 GB file (in the page cache, so
this is the host and not the disk), the native V8 host:

| read | waited for where asked (`readNow`, the EVM's misses) | awaited |
| ---: | ---: | ---: |
| 512 B | 70 µs | 70 µs |
| 4 KB | 70–100 µs | 69 µs |
| 16 KB | 84 µs | 81 µs |
| 64 KB | 143 µs | 158 µs |
| 256 KB | 375 µs | 420 µs |

About **70 µs a call and 1.2 µs a KB**. A 64 KB leaf is two calls' worth today. When the host's call
drops to ~5 µs (wac's preadv2 work, under way), the size is most of it: ~80 µs for 64 KB against ~10 µs for
4 KB. That reopens the page size (below), and it is the first reason not to cache whole leaves: a leaf is
mostly bytes nobody asked for.

`tools/measure/entrymem.wac`: a million entries of an account's size (a 33-byte key and a 40-byte value) in
a `Map` keyed by the key's bytes as text cost **about 290 bytes each** of resident memory. So **one 64 KB
leaf costs what ~220 entries do**.

## What blocks read again

`tools/mainnet/replay.wac --store --keys` runs a range of mainnet blocks on a store, each block with a
fresh `StateDb` (as after a restart), and `Store.trace` records every key looked up and every key committed:
the request stream a cache under `StateDb` and the tries would see. `tools/measure/cache.wac` gives each
read's LRU stack distance — how many distinct keys were touched since this key last was, a commit counting
as a touch — so one pass gives the hit rate of an LRU of every size. Leaves are modelled at mainnet's size
(the store the trace came from is tiny): an account's leaf is its hash's place among ~460 K account leaves
(30 GB), and a slot's either its contract's (all of a contract's storage in one leaf, the most a leaf cache
could gain) or its own hash's among ~1.7 M (110 GB; each slot alone, the least).

**Preliminary**: 64 blocks from 26,405,916 (Nov 2026), the first 16 only warming the cache. The range's
state was still being learnt from a free-tier RPC node when this was run (`--anyway`: the last few hundred
keys read as empty), so from block 24 some transactions fail and the blocks stop there; the reads per
block below are low for that reason (a complete five-block trace from 26,404,100 had ~6900 a block, not
~2600). The hit rates are per read and should hold; they will be replaced with the converged range's.

| reads a block (distinct) | accounts 334 · slots 842 · account trie nodes 612 · storage trie nodes 815 |
| --- | --- |
| writes a block (distinct) | accounts 238 · slots 436 · account trie nodes 627 · storage trie nodes 864 |

Hit rate of the reads after warming, by what is cached:

| cache | memory | all reads | accounts | slots | account trie | storage trie |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| entries, 10 K | 3 MB | 29% | 28% | 18% | 43% | 30% |
| entries, 30 K | 9 MB | 53% | 50% | 40% | 66% | 57% |
| entries, 100 K | 29 MB | **68%** | 63% | 54% | 80% | 74% |
| entries, ever touched in the trace | | 68% | 63% | 54% | 80% | 74% |
| leaves, 1000 | 64 MB | 13–31% | 5% | 27–88% | 8% | 7% |
| leaves, 10 000 | 640 MB | 37–58% | 29–35% | 42–93% | 45–51% | 31–39% |

(Leaves: the lower figure with each slot alone, the higher with a contract's storage in one leaf.)

What this says:

- **Two-thirds of a block's reads were touched in the last ~50 blocks** (ten minutes), and a cache of 100 K
  entries — 29 MB — holds all of them. The upper levels of the tries are most of the reuse (80%), then
  accounts, then slots.
- **At equal memory, entries catch two to five times what leaves do.** 64 MB of leaves is 1000 of them and
  catches 13–31%; 64 MB of entries is ~220 K and catches everything this trace can show (68%). Hashed keys
  scatter, so a leaf is kept for the one key in it someone wanted. Only a contract's storage lies together,
  and only when the contract is small enough to fit a leaf — the generous end of the range.
- **What a longer window catches is not known yet.** 64 blocks cannot show reuse over hours; the converged
  run, and a longer one, will. A cache sized for the measured window is tiny, so the size below is set by
  the heap rather than by this curve.

Commits: flushed every block, a block writes ~2170 keys (and their leaves — nearly one leaf each, since
the keys scatter); flushed every 4, 16 or 64 blocks, ~1680, ~1250 and ~1040 a block. Batching halves the
writes, as `docs/state-on-disk.md` assumed.

## Decisions

1. **The unit is the entry**: a store key and its raw value (an account's slim RLP, a slot's RLP, a trie
   node's RLP) or the fact that there is none (an empty slot, an absent account — read often, and as
   costly to miss as a present one). Not the leaf, which costs 220 entries' memory for one or two entries'
   hits; not the decoded `Known`, which costs five times the raw bytes.
2. **It lives in `Store`**, under everything: `get` and `getNow` look in it first and fill it on a miss, so
   `StateDb`, both tries and the RPC's reads share one cache and one budget. **Commits write through**: each
   change replaces its entry (a deletion becomes "none"), so the keys a block wrote are there for the next —
   which is most of the reuse above, since a block's writes are read again soon.
3. **Ranges do not fill it.** `range`/`rangeNow` (snap serving, snap's own trie building, code chunks) read
   past it, so one peer's sync of us, or ours, does not flush what the head needs.
4. **Bounded by bytes, evicted by CLOCK.** Each entry is charged its key and value lengths plus a fixed
   overhead (~220 bytes, from the 290 measured), and the cache holds **256 MB by default** (`--cache-mb`):
   about 900 K entries, nine times what the measured window needs, inside the heap the V8 host allows beside
   the interior (~100 MB at mainnet's size), the diff layers and the node. CLOCK — a ring of entries with a
   referenced bit, the hand clearing bits until it finds one clear — rather than an exact LRU, because a hit
   then only sets a bit; the curve above is LRU's and CLOCK is known to sit close to it.
5. **`Store` keeps leaves by a byte budget, 64 MB** (`LEAF_BYTES`; 4096 leaves of 16 KB). It was set to 64
   leaves first, on the reasoning that reads are the cache's; but a commit rewrites whole leaves, and with 64
   it re-read the leaves of the keys it wrote: on the five-block replay, 7216 page reads against 455 and
   70 Mgas/s against 100. The interior stays in memory, as before. While a commit is writing, no leaf is let
   go (one it has rewritten is clean before its page is written; `store_test`'s gated test shows the loss).
6. **`StateDb` stops keeping state across blocks**: its maps are the current block's (as the replay's cold
   `StateDb` is), dropped at commit; what it read is in the store's cache. The account trie it keeps open
   stays, its nodes now reread from the cache when needed rather than held as objects.
7. **Pages of 16 KB** (store format 3; a 64 KB store is refused, not overwritten). Measured once wac's
   cheaper call landed (819ab1af6: ~10 µs a call and ~1 µs a KB here): a 16 KB page reads in ~25 µs against
   ~75 µs for 64 KB, and on the five-block replay with the same memory for leaves (4 MB) 16 KB ran at 90
   Mgas/s against 70 for 64 KB. The interior grows to ~400 MB at mainnet's size, which `--max-heap` now
   allows. Values over `CHUNK` (12 KB: codes, receipts, blocks) are stored in chunks.

**The five-block replay, reconciled** (2026-11-13, back to back, nothing else running): e38c79b — the commit
that first measured 119 Mgas/s on the store — runs at 105–114 today on its own pin (wac 7f559349c), so 119
was the good end of the run-to-run spread; this design as built (16 KB pages, 64 MB of leaves, the cache, wac
819ab1af6) runs at 101–104. The 65–70 measured on the way was the 64-leaf bound (and other work running at
the same time); the leaf budget removed it. With everything in memory either way, what remains is the cache's
own cost per read, a few percent.

What this does not decide: the diff layers' flush interval (`docs/state-on-disk.md` says 128 finalized
blocks; the commit figures above support batching, and the cache makes the layers' own lookups cheaper but
does not replace them), and prefetching a block's senders and recipients in one sorted pass (layer 1 of
`docs/state-on-disk.md`, still worth it: the misses that remain are a third of the reads, each a call).

## To measure next

- The converged 64-block range (the fetch is learning its last keys), and then a longer one, for reuse
  beyond ten minutes and the size where the curve flattens.
- The cache in the node, at the head of Hoodi: hit rate, and Mgas/s on the store, against the replay's.
