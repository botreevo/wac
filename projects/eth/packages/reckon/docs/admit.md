# One command for admission

`claim admit` is the one entry point: from what you trust to a decision, with every step in between proved.

    claim admit SUBJECT ROLE --policy F
        [--checkpoint ROOT (--beacon DIR | --beacon-url URL) [--fork NAME] [--now SLOT]]
                                                                      the anchor, from the light client
        [--anchor BLOCKHASH]                                          …or an anchor you already trust
        [--rpc HOST:PORT]                                             an execution node: trusted for nothing it says
        [--registry ADDR --code-hash H]                               revocations and rejections, proved (registry v2)
        [--ens-registry ADDR --ens-registry-code H --resolver-code H] for SUBJECT ens:NAME (mainnet ENS by default)
        [--store DIR] [--mirror DIR|http://HOST:PORT|https://HOST]…  where claims and blocks are

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
found two things this now handles. A node answers several periods' updates with one Eth-Consensus-Version per
update, comma-separated. And once in five runs a live update was refused: the clock slot was read once, before
fetching, and a node's freshest updates are signed in the head slot, so when a slot passed during the fetching an
update was "signed in the future". The clock is now read as each update is checked, with the spec's 500 ms of
disparity. Shown live with `lc`: a clock read one slot early refused the optimistic update 3 times in 4, and read
after fetching, never. After the fix, 10 live runs out of 10 were admitted. (A first guess, that the optimistic
update could be no newer than the finality update, was wrong: the light client accepts that.) The optimistic update
is still not asked for; it adds nothing to a finalized anchor.

## `claim run`

`claim run SUBJECT ROLE` takes every flag `claim admit` takes, and then, if the subject is admitted, fetches it and
runs it:

    claim run ens:NAME app --policy P --checkpoint ROOT --beacon-url URL --rpc NODE --mirror http://… -- ARGS…
    claim run CID app --policy P --entry bin/app.wasm …        # a tree: PATH names the program in it
    claim run CID app --policy P --out DIR …                   # write it out instead of running it

- **What runs is what was admitted.** Every block comes through the resolver, which hashes it against its CID, and
  a file's size is checked against what its root declares. A mirror serving other bytes ends the command (exit 1)
  before anything runs.
- **It runs in the machine,** as `derive` runs a recipe: its NaNs made canonical, launched sealed (no clock, no
  random bytes, for it or anything it spawns), with no network and no environment. Its files are the machine's: a
  tree is read-only at `/in`, and `/out` is writable but held in memory and dropped at the end. A program that is one
  file sees an empty `/in`. Nothing reaches the host's disk.
- **Its stdout and exit code are the command's.** Admission's account (the anchor, the name, the chain, the
  decision) goes to stderr. Arguments after `--` are the program's, and none of them is read as a flag. The output is
  passed on when the program ends, not streamed. `--timeout MS` bounds the run.
- **Refusals:** not admitted, exit 4; a step of admission asked for and not done, exit 3, as for `admit`. In both
  cases nothing is fetched or run.
- **`--out PATH`** writes the admitted file's bytes to PATH, or the tree below PATH, and runs nothing. This is the
  native helper of K3 (docs/decisions/K3-browser.md): a web app written out from checked bytes.

`tools/run.sh` (task `reckon:run`, 16 checks) admits a one-file program and a tree from a mirror into an empty store
and runs both. It checks that admission's account stays off stdout, that the program is sealed and can't reach host
files or the environment, that a tree sees itself at `/in` read-only and may write `/out`, and that its arguments,
stderr and exit code pass through. Then it writes both out with `--out`, and checks the refusals: a client without
the endorsement runs nothing, and a mirror with other bytes for the program is caught at the fetch.

## Which names are followed

Decision K2 (docs/decisions/K2-names.md): a subject is a CID, `ens:NAME`, or `name:NAME@0xPUBLISHER`, a name in
the registry v2. The scheme is always explicit, and neither kind of name takes precedence over the other. A name is
only a pointer, and the CID it gives is admitted like any other. The policy's `names` field decides which pointers
are followed, by who can move them and how fast:

    names: { min_delay: 3600, ens: "allow" }

- `name:NAME@0xPUB` is read by proof at the anchored block (with `--rpc` and `--registry`), and read at that
  block's time: the CID in effect then, the delay in force, and any pending change. It is followed only if its delay
  is at least `min_delay` (default 0) and no shorter delay is pending. The second condition matters: a publisher who
  lowers the delay must wait out the old one, and a follower sees it coming and stops following before it applies.
- `ens:NAME` moves at once, since ENS has no delay. It is followed when `ens` is "allow", never when it is "refuse",
  and when `ens` is unset only while `min_delay` is 0. A policy with no `names` field follows both kinds, as before.
- A name not followed is refused (exit 4) before any claim is read. The same CID given directly is unaffected.

Tested in `tools/registry2.sh` (5a and 6: a followed name, a delay under the minimum, an unclaimed name, another
publisher's, a lying node) and `tools/admit-by-name.sh` (`ens: "refuse"`, `min_delay` with ens unset and with
"allow"), and unit-tested in `test/policyfile_test.wac`.
