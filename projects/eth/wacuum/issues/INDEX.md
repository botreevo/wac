# Open issues

Newest first. See `README.md` for when to file and how, and `closed/` for what has been fixed and why.

| # | summary | kind | symptom |
|---|---|---|---|
| [0008d](open/0008d-eth-call-and-eth-estimategas-take-a-whole-block-of-gas.md) | `eth_call` and `eth_estimateGas` take whatever gas the caller sends, up to a block's, with no cap; the engine is one thread, so a single free request stopped a devnet for four minutes | bug | one request stops the node |
| [0007d](open/0007d-a-block-of-some-precompile-calls-takes-minutes-to-execute.md) | Per 45M gas: bn254 add 248 s, P256VERIFY 53 s, bn254 pairing 25 s, bn254 mul 21 s, ecrecover 15 s, against 0.5 s for the interpreter. `ecAdd`/`ecMul`/`ecPairing` build the curve with `Bn.create()` on every call | performance | a block of bn254 adds takes four minutes |

2 issues, 6 closed.
