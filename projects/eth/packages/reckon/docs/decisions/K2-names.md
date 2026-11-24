# K2: names: the reckon registry, ENS, or both

**Decide:** how a person says "this app" without a CID. The choice is between the reckon registry's delayed names
(`name@0xPUBLISHER`, `contracts/Registry.sol`), ENS contenthash (`ens:NAME`, `cmd/name.wac`), or both, and if both,
which wins.

## What a name is for, here

A name is only a pointer. Admission never trusts the name: whatever CID it points at must still be admitted through
the claims (two runners, a review, and so on). So the question is not "is the name safe?" but **who can move the
pointer, how fast, and how a follower notices**.

## The two kinds

| | Reckon registry (`name@0xPUB`) | ENS (`ens:NAME`) |
| --- | --- | --- |
| Namespace | Per publisher: `hello@0xabc…`. Not human-friendly, but no squatting | Global, human: `vitalik.eth`. Owned, renewed, traded |
| Who moves it | The publisher's key only | The name's owner, or a manager or resolver they set |
| How fast | **After a delay the publisher committed to**, and a change of delay waits the old delay. Followers see a change coming and can refuse to follow (`min_delay` in v1's policy) | **At once.** No delay in ENS itself |
| Read by proof | Yes: our layout, our code (`src/registry2.wac`) | Yes for the PublicResolver's layout (`ens/src/contenthash.wac`). **No** for wildcard or off-chain (CCIP-read) resolvers: their answers are not in storage |
| Today in `claim admit` | Not wired as a subject (the reader exists: `resolveName`) | `claim admit ens:NAME` works, anchored |

## Options

1. **Registry only.** Strong change control, unfriendly names. People will put an ENS name on a web page anyway.
2. **ENS only.** Friendly, and works today. A stolen ENS key repoints the name at once. The damage is bounded,
   because the new target still has to be admitted, but a policy that trusts "whatever the publisher endorses" is
   exposed immediately.
3. **Both, as explicit schemes, no precedence.** The subject says which: `ens:NAME` or `name:NAME@0xPUB`. The policy
   can require a minimum delay for any name it follows, which only registry names can meet, or allow ENS where
   friendliness matters more.
4. **Both, with ENS pointing at a registry name.** An ENS text record (say `reckon`) holds `NAME@0xPUB`, and the CID
   comes from the registry with its delay. Friendly to type, delayed to move. It costs one more proof per
   resolution, and a stolen ENS key could still repoint the indirection at once, though not the CID.

## Recommendation

**Option 3 now, with option 4 as the friendly form later.** Explicit schemes keep each name's guarantee visible in
the subject itself, and policy decides what it will follow. That is the same rule as everything else here: nothing
is trusted implicitly. Precedence rules between the two would hide which guarantee applies.

## What changes in code

- **Option 3:** a `name:NAME@0xPUB` subject in `claim admit`, using `registry2.resolveName` at the anchor (about 50
  lines). A policy field, `names: { min_delay, ens: allow|refuse }`, read by `src/policyfile.wac`. Tests in
  `admit-by-name.sh` and the capstone.
- **Option 4, in addition:** read an ENS text record by proof. That is the PublicResolver's `texts` mapping, another
  versioned slot like contenthash, and needs its slot computation added to `packages/ens`. Then resolve the registry
  name it holds. About 150 lines, plus recorded mainnet data for a name that has such a record.
- **Options 1 and 2** remove a path: for option 1, `ens:` subjects and `src/names.wac`'s use in `claim`; for
  option 2, the registry's names (its contract's `names` mapping stays, unused).
