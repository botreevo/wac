# Registry v2

Build list item 9, a prototype: the on-chain half of attested derivations, for objects named by IPFS CIDs, read only by
proof. v1 (`contracts/TrustRegistry.sol`, `src/registry.wac`, `src/trust.wac`) is left as it was, for reference.

## What was built

| | |
| --- | --- |
| `contracts/Registry.sol` | revocations, rejection lists, delayed names. All storage, no owner, no admin, no upgrade. The layout is in its header comment |
| `contracts/Registry.bin`, `Registry.layout.json` | solc 0.8.28 output (`node tools/registry2/compile.cjs`): creation code, and the storage layout the tests are generated from |
| `src/registry2.wac` | the slots, reading them by `eth_getProof` with the account's code hash checked, a `Chain` for `admit`, and `resolveName` |
| `test/registry2_test.wac` | 10 tests: every slot against vectors from solc's layout and ethers (`tools/registry2/vectors.mjs`), the name rule, answers into a `Chain` |
| `cmd/claim.wac` | `claim admit … --rpc HOST:PORT --registry ADDR --code-hash H [--anchor BLOCKHASH]`: the `Chain` proved from the registry, in place of `Chain.none()`. A chain asked for and unreadable refuses (exit 3) |
| `cmd/registry2.wac` | a harness: `endorse`, `admit` under one fixed policy shape, `resolve`, `slot`, `cid` |
| `tools/registry2/wallet.mjs` | the writing side, with ethers |
| `tools/registry2.sh` | the end-to-end run on a wacuum devnet (`wac task reckon:registry2 -- WORKDIR`) |

**The contract.** Every CID reckon uses is CIDv1, sha2-256, with a one-byte codec, so 36 bytes. The contract checks that
shape on the way in. As a mapping key a CID is `keccak256(cid bytes)`. As a value it is two words, codec and digest, so
a name's CID is in storage whole and the reader needs nothing else.

- `revokedAt[signer][k(cid)]`: the block time. Only the signer can write it, and only once. `revoke(cid)` uses
  `msg.sender`. `revokeSigned(cid, v, r, s)` takes claims.wac's EIP-712 Revocation, so anyone can relay a signer's
  revocation. The relayed signature in the run is made by ethers, so it also checks the contract's EIP-712 hash
  independently of wac.
- `rejections[list][k(cid)]`: `{since, reason}`. The list is `msg.sender`. `reject(cid, reasonHash)` and
  `unreject(cid)`.
- `names[publisher][k(name)]`: eight words: current CID, pending CID, effectiveAt, delay, pending delay and its time.
  `claim` takes effect at once and sets the delay. `propose` waits for the delay in force. `proposeDelay` waits for the
  *old* delay, so a stolen key cannot shorten the window and then use it. `cancel` withdraws a proposal. A name at
  time t is computed from storage alone (`nameAt`): the reader applies a proposal that has come due, whether or not a
  later write has settled it.

**Admission.** `asksFor(policy, index, resolver, target)` lists every question admit could put to the chain: a
revocation of every statement in the index, and a rejection, by every followed list, of every object admission could
reach (the target, every subject and output, and each recipe's input slots). `chainFor` reads all of them at one block,
and `chainOf` turns the answers into admit's `Chain`. Asking for a superset means anything admit isn't told about has
been proved absent, not skipped.

## The end-to-end run: 47 of 47

On a fresh wacuum devnet (`tools/registry2.sh`, about 80 s; five runs in a row passed):

1. An endorsed object is admitted, with every slot proved absent.
2. A stranger's "revocation" of the endorser's statement is recorded under the stranger and changes nothing. The
   endorser's revocation lands at the slot `registry2.wac` computes: `eth_getStorageAt` is zero before and the
   revocation's time after. Admission then refuses. A second revocation is refused ("already revoked"). A revocation
   signed by the endorser and sent by a relayer refuses a second object.
3. A list the policy doesn't follow changes nothing. The followed list's rejection refuses, with its reason hash at
   `since + 1`. Unrejecting admits the object again.
4. An unclaimed name is refused. A claim resolves at once. A stranger cannot move it, and the publisher cannot claim
   it twice. During the 8 s delay the old CID holds and the proposal and the shorter delay show as pending. After the
   delay the new CID and delay are in effect with no write in between.
5. `claim admit` with a JSON5 policy file and `--rpc`: admitted with nothing set; refused while the followed list
   rejects the object; refused after the endorser revokes on chain. Without `--rpc` the same object is admitted,
   because that revocation lives only on chain. With `--rpc` pointing at nothing it is refused, not admitted.
   Then a derivation (`derive` on the V8 host, a quorum of one runner, every input endorsed): admitted; refused
   when the followed list rejects the *program* it was derived with, which `asksFor` reached through the recipe's
   slots; admitted again once it is unrejected; refused when the runner revokes its derivation on chain.
6. Through `tools/liar.mjs` (v1's lying node, unmodified), the hidden revocation and the hidden name are both refused
   because their storage proofs do not verify. Where every slot really is empty, the lie changes nothing and
   admission goes through.
7. A wrong code hash is refused ("runs other code"), and so is an address with no account.

## Findings

- **wacuum dropped revert data** (fixed). A reverting `eth_estimateGas` answered a bare `execution reverted`, and a
  reverting `eth_call` put the data in the message rather than in `error.data`, so ethers reported "missing revert
  data" for every refused transaction. wacuum now answers as geth does: code 3, `execution reverted: <reason>`, and
  the data in `error.data` (`packages/wacuum/test/revert_test.wac`). The wallet's workaround is gone.
- **A wacuum devnet proved only its head** (fixed). `--dev` finalizes every block as it makes it, and the world kept
  the finalized block's state and nothing older, so a proof asked for the header just fetched was refused ("the
  state of that block is not available") whenever a block landed in between. Through the liar, which adds a hop and a
  second proof request, that happened in 1 run in 3. A `--dev` node now keeps the last 16 blocks' states (the
  engine's `states`; `packages/wacuum/test/dev_test.wac`), and the readers here and in v1's `trust.wac` retry 8 times.
- **The liar's refusal is not always worded the same.** Depending on where the substitute proof diverges from the real
  trie, mpt says either "the proof ends where a node hashing to … was expected" or "node N hashes to …, but its parent
  named …". v1's e2e matched the first phrase only, which held only because of the shape of its tries; it now accepts
  either (fixed).
- **`tools/oracle/package-lock.json` was out of sync** with its `package.json` (fixed): it lacked `multiformats`,
  `@ipld/dag-cbor` and `cborg`, so `npm ci` refused. Regenerated; every version it already pinned is unchanged.
- **No wac blockers.** The only compiler friction was casts (`as!`, `as~`), where the diagnostics say what to write.
- **`now` belongs to the caller.** A name's meaning at a time does not depend on which block proved it, because the
  pending value and its time are in storage. A follower can therefore see a change coming for the whole delay,
  which is the point of the delay.

## Not done

- Rejections and endorsements are not relayed by signature, only revocations.
- Statements written as signed objects but never revoked on chain are still decided by `graph.wac`'s `revokedHere`. The
  chain is a second source, not a replacement.
- There is still no anchor on a devnet. On a real chain the anchor comes from `packages/lightclient` (item 8).
