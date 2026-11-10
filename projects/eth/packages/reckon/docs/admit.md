# One command for admission

`claim admit` is the one entry point: from what you trust to a decision, with every step in between proved.

    claim admit SUBJECT ROLE --policy F
        [--checkpoint ROOT --beacon DIR [--fork NAME] [--now SLOT]]   the anchor, from the light client
        [--anchor BLOCKHASH]                                          …or an anchor you already trust
        [--rpc HOST:PORT]                                             an execution node: trusted for nothing it says
        [--registry ADDR --code-hash H]                               revocations and rejections, proved (registry v2)
        [--ens-registry ADDR --ens-registry-code H --resolver-code H] for SUBJECT ens:NAME (mainnet ENS by default)
        [--store DIR] [--mirror DIR|http://HOST:PORT]…                where claims and blocks are

SUBJECT is a CID, or `ens:NAME` for whatever the name's contenthash says. The steps, each one checked:

1. **Anchor.** With `--checkpoint`, the light client starts from that beacon block root and the beacon data in
   `--beacon` (bootstrap.ssz, updates.ssz, finality.ssz, optimistic.ssz as `packages/lightclient/tools/mainnet.sh`
   fetches them). It follows the sync committee's signatures to the finalized header and takes its execution block
   hash. With `--anchor`, the hash is yours. With neither, there is no anchor, and every chain answer says so.
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
the same code. `lc` stays the light client's own command. Fetching beacon data live is `tools/mainnet.sh`'s job;
`--beacon` reads what it fetched, and the recorded mainnet data is such a directory.
