# One command for admission

`claim admit` is the one entry point: from what you trust to a decision, with every step in between proved.

    claim admit SUBJECT ROLE --policy F
        [--checkpoint ROOT (--beacon DIR | --beacon-url URL) [--fork NAME] [--now SLOT]]
                                                                      the anchor, from the light client
        [--anchor BLOCKHASH]                                          …or an anchor you already trust
        [--rpc HOST:PORT]                                             an execution node: trusted for nothing it says
        [--registry ADDR --code-hash H]                               revocations and rejections, proved (registry v2)
        [--ens-registry ADDR --ens-registry-code H --resolver-code H] for SUBJECT ens:NAME (mainnet ENS by default)
        [--store DIR] [--mirror DIR|http://HOST:PORT]…                where claims and blocks are

SUBJECT is a CID, or `ens:NAME` for whatever the name's contenthash says. The steps, each one checked:

1. **Anchor.** With `--checkpoint`, the light client starts from that beacon block root and follows the sync
   committee's signatures to the finalized header, then takes its execution block hash. The beacon data comes from
   one of two places, and is believed only as far as the signatures carry it:
   - `--beacon DIR`: files as `packages/lightclient/tools/mainnet.sh` fetches them (bootstrap.ssz, updates.ssz,
     finality.ssz).
   - `--beacon-url URL`: fetched live from a beacon node's light-client REST API: the checkpoint's bootstrap, the
     updates from its period to the clock's, and the finality update, each answer's fork from its
     Eth-Consensus-Version.

   The optimistic update is not used: the anchor is the finalized block. With `--anchor`, the hash is yours. With
   neither, there is no anchor, and every chain answer says so.
2. **Name.** For `ens:NAME`, the ENS registry's record and the resolver's contenthash are read by proof at the
   anchored block (`src/names.wac`, the same code as `cmd/name.wac`). The CID is what the name points at there.
3. **Chain.** With `--registry`, every revocation and rejection admission could ask about is proved at that block
   (`src/registry2.wac`).
4. **Claims.** The local index together with every mirror's, every signature verified (docs/claims-mirror.md).
5. **Decision.** The policy over all of it (`src/admit.wac`).

A step that was asked for and cannot be completed refuses (exit 3), never admits on no answer. Every line of the
output says which step it is and what it rests on.

**What is not folded in.** The v1 commands (`reckon check`, `reckon run`, `trust.json5`) are untouched: whether to
keep, quarantine or delete v1 is not decided here. `cmd/name.wac` and `cmd/registry2.wac` stay as narrower tools over
the same code. `lc` stays the light client's own command.

**Checked live, once** (2026-11-10, against https://lodestar-mainnet.chainsafe.io). From the recorded checkpoint
`0xa835…e937` (slot 15621760, period 1906), `--beacon-url` fetched the updates across the period boundary and arrived
at finalized execution block `0xc3da8467…`. That is the block `packages/lightclient/tools/mainnet.sh` and `lc` gave
from the node's own checkpoint minutes before. Five more runs from fresh checkpoints gave the same. That check also
found two things this now handles: a node answers several periods' updates with one Eth-Consensus-Version per
update, comma-separated; and a live optimistic update can be no newer than the finality update just applied, which
the light client refuses. That refusal is why the optimistic update is not asked for.
