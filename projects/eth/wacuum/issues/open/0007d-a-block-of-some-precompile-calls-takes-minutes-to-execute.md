# 0007d — a block's worth of some precompile calls takes seconds to minutes to execute

- **Status:** open
- **Reported by:** agent-d (the cloud session that built `wacuum-devnet`)
- **Date:** 2026-10-30
- **Kind:** performance
- **Symptom:** a 45M-gas block of bn254 additions takes about four minutes; a devnet making a block every 2 s stops for that long

## Reproduction

A contract that calls one precompile in a loop until 200,000 gas is left — `calldata[0:32]` names the
precompile, the rest is its input, copied to memory once:

    602036038060206000376000355b60408283600084 5afa50 62030d40 5a11 61000d 5700

deployed on a `--dev` chain, then `eth_call` to it with 2M gas, scaled to the 45M of a block. Every input was
checked valid first (an invalid one fails at once and would flatter the number). Node host, `4f48eaa` (lib),
`wac` built from `96e5a0cfe`; `tools/bench.wac` on the same machine gives 84 Mgas/s arithmetic, 31 keccak.

| precompile | gas each | rate | 45M gas takes |
|---|---|---|---|
| bn254 add (0x06) | 150 | 0.2 Mgas/s | **248 s** |
| P256VERIFY (0x100) | 6,900 | 0.8 Mgas/s | **53 s** |
| bn254 pairing, 2 pairs (0x08) | 113,000 | 1.8 Mgas/s | **25 s** |
| bn254 mul (0x07) | 6,000 | 2.2 Mgas/s | **21 s** |
| ecrecover (0x01) | 3,000 | 3.0 Mgas/s | **15 s** |
| blake2f, 1M rounds (0x09) | 1 a round | 22 Mgas/s | 2.0 s |
| KZG point evaluation (0x0a) | 50,000 | 24 Mgas/s | 1.9 s |
| modexp, 256-bit modulus, full exponent (0x05) | 27,036 a tx | — | 1.9 s |
| sha256, 1 KB (0x02) | 444 | 49 Mgas/s | 0.9 s |
| modexp, 2048-bit (0x05) | 7.9M a tx | — | 0.3 s |
| ripemd160, 1 KB (0x03) | 1,560 | 136 Mgas/s | 0.3 s |

Expected: every precompile within a small factor of the interpreter's own rate, since gas prices are set to
make that so on reference clients.
Actual: five of them are 10x to 400x slower per gas than the interpreter.

## Notes

On a devnet this is more than speed. Its ether is free (`wacuum-devnet`'s faucet gives 10 ETH a day), and at
devnet fees a 45M-gas transaction costs a few hundredths of an ether, so anyone can fill blocks with bn254
additions and stop the chain for four minutes a block. The node answers nothing while it executes one.

Where to look first: `src/crypto/bn254.wac`'s `ecAdd`, `ecMul` and `ecPairing` each start with `Bn.create()`,
building the curve (and its pairing constants) for every call, which at 150 gas a call is likely most of the
0.8 ms an addition costs; made once and kept, the addition itself should be microseconds. ecrecover at about
1 ms a recovery is the same cost a transfer's sender recovery has (`tools/bench.wac`'s transfers run at 20
Mgas/s), and P256VERIFY at about 7 ms a verification is the slowest per call — both are worth a look at how
their curve and its precomputation are built per call.
