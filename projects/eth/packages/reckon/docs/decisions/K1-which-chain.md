# K1: which chain for revocations, rejections and names

**Decide:** where `contracts/Registry.sol`'s records (revocations, rejection lists, delayed names) live for real use:
Ethereum L1, an L2 (and which), or the Ethereum Attestation Service (EAS).

## What the choice must preserve

Reckon reads the chain only by proof. A client checks a storage slot against a state root that the light client
proved from a checkpoint (docs/anchoring.md). Two properties follow, and any option must keep both:

1. **Absence is provable.** "Not revoked" is a proof that a slot is empty. That needs the slot to be computable from
   what the client already knows: `revokedAt[signer][keccak(statement CID)]`. A design where the key is something
   the client cannot compute, such as an id assigned at write time, turns "not revoked" into "no one told me".
2. **The state root is reachable from the checkpoint.** `lc` proves L1 execution state roots, finalized, about two
   epochs (roughly 13 minutes) behind the head.

## Options

| | L1 (Ethereum mainnet) | An L2 | EAS |
| --- | --- | --- | --- |
| Can `lc` reach the state? | **Yes, today.** `claim admit --checkpoint … --registry …` works now, given a deployment | Indirectly. Prove the L2's state root as posted to its L1 contract, then the slot under it. One more proof step per read | EAS on L1 or an L2 inherits that chain's answer |
| Absence provable? | Yes (the registry's layout) | Yes (the same contract, deployed there) | **No**, for revocations of reckon's statements. An EAS attestation's id (`uid`) hashes its timestamp and other write-time fields, so a client cannot compute where a revocation would be. It needs an indexer, which is to say trust |
| When does a revocation count? | At L1 finality, about 13 min | OP Stack with fault proofs: the output root is final after the challenge window, about a week, unless the proposer is trusted sooner. ZK rollups: once a validity proof lands on L1, typically hours | As its chain |
| Cost per write | An SSTORE plus a transaction: on the order of a dollar or more, varying with gas | Cents | As its chain, plus EAS's own bookkeeping |
| New code in reckon | A deployment, and defaults for its address and code hash | An L2-root verifier per rollup family (below) | An EAS reader and an index source; changed semantics |

## Recommendation

**L1 now; an L2 only if write volume makes L1's cost hurt; EAS not for revocations.**

- Revocations and rejections are rare, and when they happen they matter: a key was stolen, or a build was
  malicious. Paying L1 prices for those, and having them count at L1 finality with no extra proof layer, is the
  right trade. Delayed names are also rare writes.
- If an L2 becomes necessary, prefer one whose state roots are final on L1 quickly, which in practice means a ZK
  rollup. A revocation that takes a week to count is a week of exposure.
- EAS is a good *publication* channel for endorsements, which are positive claims where absence does not matter.
  It could become one more source for the claim index, beside mirrors. It cannot carry revocations that a client
  must be able to prove absent.

## What changes in code

- **L1:** deploy `Registry.sol` as it is (no admin, no upgrade). Record its address and runtime code hash beside
  the ENS ones in `src/names.wac`'s defaults, and let `claim admit` default `--registry` and `--code-hash` to them.
  `tools/anchor.sh` and the capstone gain a recorded-mainnet registry read. About 30 lines, plus recorded data.
- **An L2:** a verifier from an L1 state root to the L2's state root for that rollup family. For OP Stack, the
  dispute game's root claim is an output root, the hash of a version, the L2 state root, the message passer's
  storage root and the block hash; prove it from L1 storage, check the preimage, then prove the slot under the L2
  state root. A finality policy is also needed (a minimum age for output roots, or acceptance of the proposer).
  Several hundred lines per family, with recorded fixtures.
- **EAS:** a reader for EAS's attestation layout, a schema for reckon statements, an index source for `uid`s, and
  admission semantics where revocation is best-effort. Not recommended for this use.
