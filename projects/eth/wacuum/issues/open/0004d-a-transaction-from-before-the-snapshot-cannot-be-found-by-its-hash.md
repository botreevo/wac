# 0004d — a transaction from before the snapshot cannot be found by its hash

- **Status:** open
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** missing feature
- **Symptom:** `eth_getTransactionByHash` answers `null` for a transaction whose block the node serves

## Reproduction

A `--dev` node with `--snapshot-every 20`; send a transaction in the first few blocks; let it pass block 40;
restart it on the same `--datadir`. Then `eth_getBlockByNumber` for the transaction's block answers the
block with the transaction in it, and `eth_getTransactionByHash` for that transaction answers `null`.

Expected: the transaction, with its block, as `eth_getTransactionByHash` answers for a block that ran.
Actual: `null`.

## Notes

The README and `cmd/wacuum.wac` say receipts are kept only for blocks that ran, which is a fair limit:
there is nothing to make them from. The transaction itself is in the body the node keeps, so finding it by
hash needs only the index the blocks that ran already get, filled from the bodies while the log replays.
`wacuum-devnet` builds that index itself for its explorer, from `eth_getBlockByNumber`; a wallet or a library
asking the node has no such way round. Bounded by `--history`, like everything else since `95e34dd`.
