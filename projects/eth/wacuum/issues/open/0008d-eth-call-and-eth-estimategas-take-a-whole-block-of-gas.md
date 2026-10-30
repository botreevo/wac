# 0008d — `eth_call` and `eth_estimateGas` run up to a whole block's gas, and the node answers nothing meanwhile

- **Status:** open
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** bug
- **Symptom:** one RPC request stops a node — blocks, peers, every other request — for seconds to minutes

## Reproduction

`0007d`'s looping contract, and on a `--public-rpc` (or `--dev`) node:

    {"method": "eth_call", "params": [{"to": "<looper>", "gas": "0x2aea540", "data": "<bn254 add input>"}, "latest"]}

Answered after about 240 seconds. `eth_estimateGas` on the same call runs it several times over in its search.

Expected: a public node caps what one call may spend, as `geth --rpc.gascap` (50M by default) and others do,
and with a cap its operator can set far lower.
Actual: `ethCall` takes the `gas` the caller sends, or the head's gas limit without one, with no ceiling.

## Notes

The engine runs on one thread, so the cost is everyone's: a devnet producing blocks every 2 s missed two
minutes of them during one such call. A cap is a flag and a `min`; it does not fix `0007d`, which is the same
time spent inside a block, but it stops a request that costs nothing from doing it.
