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

## What a client of the engine can and cannot cap (2026-11-02, at `ca9b924`)

`wacuum-devnet` now caps both in front of the engine (`src/gascap.wac`, `--rpc-gas-cap`, 10M by default):
`eth_call` is rewritten to run with at most the cap, and `eth_estimateGas` is first tried as an `eth_call` at the
cap and refused if that fails. Measured with `0007d`'s looper over bn254 mul, the slowest per gas now:

| request | before | behind the cap |
|---|---|---|
| `eth_call`, a block's gas | 4.6 s | 1.3 s |
| `eth_estimateGas`, a call that fails | ~1.7 s, one run at 16.7M | under the cap's one run |
| `eth_estimateGas`, a call that succeeds with any gas it is given | 4.9 s | **4.9 s** |

The last row is what only the engine can fix. `estimateGas` ignores the caller's `gas` and starts its search at
the transaction limit (16,777,216 under Osaka), so a call that runs until its gas is low — the looper, any
`while (gasleft() > x)` — costs about twice that limit in execution, whatever a client in front of it does.
What would bound it: take `min(caller's gas, a cap)` as the top of the search, as geth does with
`--rpc.gascap`; and, as geth also does, run the call once at the top first and search only between the gas it
actually used and the top, which takes the two dozen runs down to a handful for ordinary calls.
