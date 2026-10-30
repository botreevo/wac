# 0002d — the RPC port takes every connection and waits for ever on each

- **Status:** open
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** bug
- **Symptom:** the node stops — the same as `0001d`, from the Engine API / JSON-RPC port

## Reproduction

`cmd/wacuum.wac`'s `serveEngine` and `answer` are the shape `wacuum-devnet` started from, and that copy
stopped for good with 130 connections each sending `GET / HTTP/1.1\r\n` and nothing more. Not run against
`cmd/wacuum.wac` itself; the code is the same: `answer` is started for every accepted socket and loops on
`recv` until the request is whole, with no deadline and no cap.

Expected: slow or silent clients are dropped; everybody else is answered.
Actual: past about 128 such connections the program stops (wac `issues/system/0373d`).

## Notes

The Engine API faces a consensus client on the same machine, where this does not come up. `--public-rpc`
and `--dev` (which turns it on) are where it does: that port is meant for wallets, so sooner or later for a
network. The fix is `wacuum-devnet`'s: at most a few dozen connections in flight, and one task that closes any
connection not answered within ten seconds.
