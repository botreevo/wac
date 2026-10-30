# Open issues

Newest first. See `README.md` for when to file and how, and `closed/` for what has been fixed and why.

| # | summary | kind | symptom |
|---|---|---|---|
| [0004d](open/0004d-a-transaction-from-before-the-snapshot-cannot-be-found-by-its-hash.md) | After a restart from a snapshot, `eth_getTransactionByHash` is `null` for a transaction in a block the node serves: the by-hash index is built only for blocks that ran | missing feature | `null` for a transaction whose block is served |
| [0003d](open/0003d-a-node-cannot-follow-a-chain-that-has-no-consensus-client.md) | A peer of a devnet connects and can fetch every block but stays at 0: the only sync target is one a consensus client names. A `--follow` taking a peer's announced head would do | missing feature | a peer stays at block 0 |

2 issues, 4 closed.
