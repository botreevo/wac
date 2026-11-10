# Anchoring chain reads

Every chain read in reckon is a storage slot proved against a header's state root: revocations and rejections in the
registry (`registry2.wac`, `claim admit --rpc`) and a name's record and contenthash (`cmd/name.wac`). A proof is only
as good as the header it is checked against, so **which header** is the whole question.

## Without an anchor

The node's own latest block is taken, and checked only against the node's own `hash` field. That proves the node
consistent with itself and, through the code-hash check, that the account runs the expected contract. It does not
prove that the chain is anyone else's: a node can invent a whole state with a header to match. Every tool says
`no anchor` when it answers this way.

## With an anchor

`--anchor BLOCKHASH` names the block. The tool asks for that block by hash, re-encodes its header and hashes it
(`ethrpc.headerOf`), refuses it unless it hashes to the anchor, and asks for every proof at that block. So from the
anchor on, nothing the node says is believed: the header is fixed by its hash, the state root is fixed by the header,
and each slot is fixed by the root. The node can still refuse to answer, or not have the block's state.

**Where the anchor comes from is the only trust left.** On mainnet it comes from the light client. `lc`
(packages/lightclient) starts from a beacon checkpoint you trust, follows the sync committee's signatures, and prints
the finalized execution block's hash. That hash is the anchor, so the chain of trust is:

    checkpoint (trusted) → sync committee → finalized beacon header → execution block hash (lc)
      → header (hashes to it) → state root → account (code hash) → slot

`tools/anchor.sh` runs that chain offline on the recorded mainnet data (packages/lightclient/test/mainnet):
- `lc` proves the finalized execution block's hash from the checkpoint;
- a replaying node serves the recorded block and proofs;
- `name resolve vitalik.eth --anchor <that hash>` gives the same CID `lc` does;
- a node that serves another header for the anchor, one that changes a proof, and an anchor not from `lc` are each
  refused.

## On a devnet

A devnet has no beacon chain, so no light client can supply an anchor. `--anchor` still means the same thing there:
take a block hash from somewhere you trust (here, from the node itself at a moment you chose), and every later read
is of that block's state and no other. `tools/anchor.sh`'s devnet half shows it with the registry: a revocation
written after the anchor is not seen by an anchored `claim admit`, and is seen by an unanchored one. An anchored read
of a block whose state the node no longer keeps is refused, not answered from another block. (A wacuum `--dev` node
keeps the last 16 blocks' states.)

## Code hashes

The code-hash flags (`--code-hash`, `--registry-code`, `--resolver-code`) stay required. With an anchor they are no
longer what makes the read trustworthy; the anchor is. But they still pin *which contract* the address must run, so
an address that changed hands, or a typo, is refused rather than read with the wrong layout. For mainnet ENS, read
from the account proofs at the anchored block 26382137:

| account | address | runtime code keccak256 |
| --- | --- | --- |
| ENS registry | `0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e` | `0xd6bfd5d6f1384a1f6ea57b8a8412de5552f138d42021cf7c4941e33206f529e4` |
| PublicResolver (vitalik.eth's) | `0x231b0ee14048e9dccd1d247744d114a4eb5e8e63` | `0x19257636fde18e27704b400659de2cbaab55488586c18cd5b6d67f6417c8c19a` |

## Retrying

A read is tried again (up to 8 times) only when trying again can help: the node did not have the block's state, or
the request did not get through (`registry2.wac`'s `transient`). A proof that does not verify, a header that does not
hash to its anchor, or code that is not the expected code is refused at once.

## Not here

`lc` and the readers are joined by the shell (`tools/anchor.sh` reads the hash `lc` prints), not by one command. The
mainnet run is on recorded data: a live run needs an execution node that keeps the anchored block's state, and
`lc`'s finalized block is minutes old, which most full nodes keep. The registry v2 is deployed only on devnets, so
anchored registry reads are shown there.
