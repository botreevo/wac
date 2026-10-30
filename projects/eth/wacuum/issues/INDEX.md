# Open issues

Newest first. See `README.md` for when to file and how, and `closed/` for what has been fixed and why.

| # | summary | kind | symptom |
|---|---|---|---|
| [0004d](open/0004d-a-transaction-from-before-the-snapshot-cannot-be-found-by-its-hash.md) | After a restart from a snapshot, `eth_getTransactionByHash` is `null` for a transaction in a block the node serves: the by-hash index is built only for blocks that ran | missing feature | `null` for a transaction whose block is served |
| [0003d](open/0003d-a-node-cannot-follow-a-chain-that-has-no-consensus-client.md) | A peer of a devnet connects and can fetch every block but stays at 0: the only sync target is one a consensus client names. A `--follow` taking a peer's announced head would do | missing feature | a peer stays at block 0 |
| [0002d](open/0002d-the-rpc-port-takes-every-connection-and-waits-for-ever-on-each.md) | `serveEngine` takes every connection and waits on each with no deadline; with `--public-rpc` facing a network, ~130 silent clients stop the node (wac `issues/system/0373d`) | bug | the node stops for good |
| [0001d](open/0001d-the-p2p-port-takes-every-connection-and-200-idle-ones-stop-the-node.md) | The p2p port accepts every connection with no cap or handshake deadline; 200 silent ones stopped a node for good, blocks and all (wac `issues/system/0373d`) | bug | the node stops for good |

4 issues, 2 closed.
