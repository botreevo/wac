# 0003d — a node cannot follow a chain that has no consensus client

- **Status:** closed
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** missing feature
- **Symptom:** a peer connects, sees the blocks, and stays at block 0

## Reproduction

A `--dev` node (or `wacuum-devnet`) with `--p2p-port 30311`, and a second node from the same genesis:

    wacuum --genesis genesis.json --jwt-secret jwt.hex --datadir peer --port 8552 --peer enode://…@127.0.0.1:30311

The second logs `p2p: 127.0.0.1:30311: wacuum/v0.1.0, serving blocks 0-38` and its `eth_blockNumber` stays
`0x0`. Sending it `engine_forkchoiceUpdatedV3` with the first node's head answers `SYNCING`, it logs
`syncing 46 blocks`, and a second, identical `forkchoiceUpdated` answers `VALID` and moves its head; its state
root at block 46 matches the first node's. So the sync works; nothing starts it.

Expected (for a devnet): a way to follow the chain its peers serve.
Actual: the only sync target is one a consensus client names, and a devnet has none.

## Notes

The README's "Running the node" is right for a chain with a consensus client. For a devnet, a `--follow`
that takes the head a peer announces (eth/69's `Status` and `BlockRangeUpdate` carry its latest block hash)
as the target, and makes it the head once its blocks are in, would let anyone run a node beside one. It
trusts the peer for the fork choice, which for a devnet whose blocks one node makes is the truth anyway.
Until then `wacuum-devnet` tells its operators to leave `--p2p-port` off (which `0001d` also asks).

## Resolution

`--follow`: with no consensus client, the node takes the highest head a peer announces (from its `Status`,
then its `BlockRangeUpdate`s, whose latest hash peers now keep), fetches the blocks up to it from that peer,
and makes it the head, safe and finalized — as a `--dev` node does with its own blocks. Without `--genesis`
it is on the dev chain; it needs no `--jwt-secret`, and turns on `--public-rpc`. A block at a time is no
longer logged, only a longer catch-up.

The reproduction, on the Node host: a `--dev` node with `--p2p-port`, and `wacuum --follow --peer enode://…`
beside it. The follower stayed a block behind; a transfer sent to the follower's RPC was gossiped to the
first node and mined, and both answered the same balance; block 5 had the same hash and state root on both.
Stopped for ten seconds and started again, the follower replayed its log and fetched the ten blocks it had
missed. The README's devnet section says how.
