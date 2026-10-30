# 0001d — the p2p port takes every connection, and 200 idle ones stop the node for good

- **Status:** open
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** bug
- **Symptom:** the node stops — no blocks, no RPC, no peers — and stays stopped

## Reproduction

A node with `--p2p-port 30311` (here `wacuum-devnet`, which runs the same `listen`), then:

```python
import socket
socks = [socket.create_connection(("127.0.0.1", 30311)) for _ in range(200)]   # and send nothing
```

Expected: the silent connections are dropped after a handshake timeout, and the node goes on.
Actual: the node stops answering anything, and does not recover when the 200 connections close.

## Notes

Two things together. `src/p2p/node.wac`'s `listen` accepts every connection and starts `inbound` on it with
no cap and no deadline, and `--max-peers` limits only the dialling that discovery does. And on wac's
JavaScript hosts a program has 128 host calls in flight at most, the next waiting for ever (wac
`issues/system/0373d`): each silent connection holds one pending `recv`.

What would hold until wac fixes its side: count inbound connections against `--max-peers` (or a cap of their
own) and stop accepting while full, and close a connection whose RLPx handshake has not finished within a few
seconds — closing ends its `recv` and frees the call. `wacuum-devnet`'s `src/server.wac` does both for HTTP.
