# 0005d — a full block from `eth_getBlockByNumber` recovers every sender again, every time

- **Status:** closed
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** performance
- **Symptom:** about a millisecond a transaction for each answer, on the Node host

## Reproduction

A block of 157 transfers; `eth_getBlockByNumber` with `true` for it, repeated: 175 ms each, against about
1 ms for the same block with `false`.

Expected: the senders worked out once, when the block was imported, and reused.
Actual: `src/engine/eth.wac`'s `txJson` calls `decodeTransaction`, which recovers the sender from the
signature, while everything in `engine.wac` decodes through `decodeWith(…, this.senders)` and its cache.

## Notes

Passing the engine's `SenderCache` to `blockJson` and `txJson` (and so to `decodeWith`) should be the whole
fix; `eth_getTransactionByHash` and `eth_getBlockReceipts` are the other callers to check. `wacuum-devnet`
caches whole block answers in front of this for its explorer, whose page of a busy block was 175 ms a view
and all of the node's time under modest load.

## Resolution

`blockJson` and `txJson` take the engine's `SenderCache` and decode through `decodeWith`, as everything in
`engine.wac` does; `eth_getTransactionByHash`, for a mined or a pending transaction, passes it too
(`eth_getBlockReceipts` decodes nothing). A block of 150 transfers made by `--dev`'s producer, asked for
with full transactions: 4–7 ms an answer on the Node host, where it was 175 ms for 157.
