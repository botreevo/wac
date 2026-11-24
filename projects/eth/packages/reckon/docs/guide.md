# Using reckon

This guide covers how to name things, run recipes and sign what they gave, vouch for things, publish your claims, and
decide what to trust. It ends with a reference for the policy file and every command. The design is in the README and
the explainer. This is the how.

## What you need

- **wac**, at the commit `wac.lock` pins. Run `sh tools/deps.sh` from wac-eth's root, which also fetches the pinned
  sources.
- **A second engine**, to witness on one: wac's native host on wasmtime (`./bootstrap.sh --host wasmtime` in wac).
  The tools take its path as `WASMTIME_WAC`.
- **node** for the JavaScript runners and oracles, and **cargo** for wac's Rust assembler. The bootstrap machines need
  `LADDER`, wac's `bootstrap/rust-ladder` binary.

Build the commands once, from wac-eth's root:

    wac build --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o obj
    wac build --allow-read --allow-write --allow-run packages/reckon/cmd/derive.wac -o derive
    wac build --allow-read --allow-write --allow-net --allow-env --allow-run packages/reckon/cmd/claim.wac -o claim
    wac build --allow-read --allow-write --allow-run packages/reckon/cmd/boot.wac -o boot
    wac build --allow-read --allow-write --allow-run --allow-net packages/reckon/cmd/deps.wac -o deps

Every command keeps objects and claims in a store directory: `--store DIR`, `.objects` by default. Every command also
reads from mirrors: `--mirror DIR`, or `--mirror http://HOST:PORT` / `https://HOST` (a trustless gateway). Every block
from anywhere is re-hashed, so a store or a mirror is trusted only to be there.

## 1. Name something

    wac obj.wasm add DIR                 # a directory's CID under unixfs-v1-2025 (hidden files kept, no links, no modes)
    wac obj.wasm cat CID [PATH]          # a file's bytes, checked
    wac obj.wasm ls CID                  # a tree's files

The CID is the same one any IPFS tool gives the same files, so any IPFS node or gateway can serve them.

## 2. Run a recipe, and say what it gave

A recipe is a program, its arguments and its input, as one tree, together with the machine and the object format.

    wac derive.wasm recipe --program app.wasm --args args.txt --in DIR     # prints the recipe's CID
    wac derive.wasm run RECIPE --key my.key --runner "my-runner/1 v8"      # prints the output's CID, then the claim's id
    $WASMTIME_WAC derive.wasm run RECIPE --key my2.key --runner "my-runner/1 wasmtime"

- **Machine.** `run` runs the program on `wasm-gc/wac-host/3` (docs/machines/wasm-gc-wac-host-3.md): sealed,
  canonical NaNs, its input read-only at `/in`, its `/out` kept.
- **Output.** The output tree is `status`, `log` and `out/`.
- **Claim.** With `--key`, `run` signs a derivation ("recipe R gives output O, on this runner") into the store's
  claim index.
- **No claim.** A run past the runner's limits gives nothing and claims nothing.

**Before your witness counts anywhere that asks for conformance**, witness the machine's conformance suite under the
same runner name: run every case in its `cases` file with your key (docs/conformance.md).

Something established another way, such as another runner or a hardware attestation, is signed with
`wac claim.wasm derivation RECIPE OUTPUT --runner NAME --key F`.

`claim slots RECIPE` lists a recipe's inputs. `claim origins CID` lists what derived an object, and
`claim dependents CID` what was derived from it.

## 3. Vouch for something, or against it

    wac claim.wasm endorse CID "reviewed for memory safety" --key reviewer.key
    wac claim.wasm reject CID "backdoored, see advisory 12" --key security.key   # your rejection list
    wac claim.wasm revoke STATEMENT --key reviewer.key                              # only a statement you signed

Each one prints the statement's id. A revocation can't be undone. For revocations and rejections that everyone must
see promptly, the registry contract holds them on chain (docs/registry2.md), and admission reads them by proof.

## 4. Publish your claims

    wac claim.wasm publish MIRROR_DIR        # the local index and its blocks, added to what MIRROR_DIR holds

Serve `MIRROR_DIR` with any web server (with `Access-Control-Allow-Origin: *` if pages are to read it;
`tools/serve.py` does). Others then read it with `--mirror http://HOST[/PATH]`. To be found, list it in a manifest
(`claim manifest reckon-mirrors.json --lists URL`), and a client follows that with
`claim mirrors https://…/reckon-mirrors.json` (docs/discovery.md). A mirror can withhold a claim
but can't forge one: every signature is checked, and anything that fails is left out and reported.

## 5. Decide

Write a policy (the reference below), then:

    wac claim.wasm admit CID ROLE --policy policy.json5 [--mirror …]
    wac claim.wasm admit ens:NAME ROLE --policy policy.json5 \
        --checkpoint 0xBEACON_BLOCK_ROOT --beacon-url https://BEACON_NODE --rpc https://EXECUTION_NODE [--mirror …]

`admit` prints its account, ADMITTED or REFUSED, and exits 0, 4 (refused) or 3 (a step it was asked for could not be
done). With `--checkpoint`:

- the light client proves the finalized block;
- the name is read by proof at it;
- with `--registry`, revocations and rejections are proved there too.

The only thing trusted is the checkpoint you gave (docs/admit.md).

    wac claim.wasm run SUBJECT ROLE --policy policy.json5 [the same flags] [-- ARGS…]   # admit, fetch, check, run
    wac claim.wasm run SUBJECT ROLE --policy policy.json5 … --out PATH                  # …or write it out instead

## 6. Pin your dependencies

    wac deps.wasm pin          # each wac.lock entry gains `cid`, its source tree's root
    wac deps.wasm check        # refuse a cache that differs from its pin
    wac deps.wasm fetch [--git]
    wac deps.wasm admit ROLE --policy policy.json5

## 7. The bootstrap's machines

wac's bootstrap ladder starts from text a person can read. Two of its steps are machines with two runners each,
`wac-l0/1` (docs/l0-machine.md) and `wac-flatten/1` (docs/flatten-machine.md):

    wac boot.wasm recipe --source boot/l1.l0                         # an L0 text to assemble
    wac boot.wasm recipe --tree packages/wacc/src --entry api.wac    # a module graph to flatten
    wac boot.wasm run RECIPE --tool "CMD" --key F --runner NAME      # CMD IN OUT: tools/boot/ has the adapters

## The policy file

JSON5. Nobody's policy but yours applies to you, and there is no default list of signers.

    {
      signers: { v8: "0x…", wasmtime: "0x…", reviewer: "0x…" },     // names for addresses; rules use the names
      roots: ["bafy…"],                                              // objects you accept as they are
      machines: ["wasm-gc/wac-host/3"],                              // machines whose derivations count
      formats: ["unixfs-v1-2025+hidden"],                            // object formats likewise
      reject_lists: ["0x…"],                                         // whose rejections you follow
      conformance: { "wasm-gc/wac-host/3": "bafy…suite" },           // count a runner only once it has shown the suite
      names: { min_delay: 3600, ens: "refuse" },                     // which names you follow, and how slow they must move
      roles: {
        app: [RULE, RULE, …],                                        // alternatives: any one admits
        …
      },
    }

The rules, any of which a role may list:

| rule | holds when |
| --- | --- |
| `"root"` | the object is one of `roots` |
| `{ endorsed: { by: [NAME…], at_least: N } }` | N of those signers endorsed it, unrevoked |
| `{ derived: { by: [NAME…], at_least: N, runners: K, slots: { SLOT: ROLE, … }, other: ROLE } }` | a recipe that gives it has N witnesses from `by` on K different runner names, under an accepted machine and format, and each input slot is admitted in the role given (`other` for the rest) |
| `{ within: { role: ROLE, path: "out/app.wasm" } }` | it is the file at `path` in an output admitted as ROLE: a built program taken out of its build |
| `{ analysis: { analyser: CID, slot: SLOT, path: PATH, expect: TEXT, by: [NAME…], at_least: N } }` | a witnessed run of `analyser` on it, with the object in `slot`, wrote TEXT at PATH |
| `{ agree: [RULE, RULE, …] }` | every rule holds, each `derived` one through a different recipe: unrelated origins agreeing (diverse double-compiling) |

Whatever else holds, an object that a followed rejection list names is refused, and a statement revoked by its
signer counts for nothing.

## Command reference

| command | does |
| --- | --- |
| `obj add DIR` · `add-git REPO COMMIT` · `cat CID [PATH]` · `ls CID` · `car CID OUT` · `import-car FILE` | objects under `unixfs-v1-2025` in a store, checked on every read |
| `derive recipe --program F [--args F] [--in DIR] [--machine M]` | a `wasm-gc/wac-host/3` recipe (or `/2` with `--machine`) |
| `derive run RECIPE [--timeout MS] [--key F --runner NAME]` | run it; with a key, sign the derivation |
| `derive canon IN OUT` | a module with canonical NaNs, as `run` makes it |
| `boot recipe (--source F \| --tree DIR --entry PATH)` · `boot run RECIPE --tool CMD [--key F --runner NAME]` | the bootstrap's `wac-l0/1` and `wac-flatten/1` |
| `claim address --key F` | the address a key signs as |
| `claim endorse CID SCOPE` · `reject CID REASON` · `revoke ID` · `derivation RECIPE OUTPUT --runner NAME` (each `--key F`) | sign a statement into the store's index |
| `claim slots RECIPE` · `origins CID` · `dependents CID` | the claim graph |
| `claim admit SUBJECT ROLE --policy F [anchor and chain flags]` | the decision, and why (docs/admit.md) |
| `claim run SUBJECT ROLE --policy F […] [--out PATH] [-- ARGS…]` | admit, fetch, check and run it in the machine, or write it out |
| `claim publish DIR` | the local index into a mirror |
| `claim mirrors URL` · `claim manifest OUT [--lists URL]… [--follow URL]…` | find mirrors from a manifest; write one (docs/discovery.md) |
| `deps pin` · `check` · `fetch [--git]` · `cids` · `admit ROLE --policy F` | `wac.lock` pinned by CID (docs/lock.md) |
| `name resolve NAME --rpc … [--anchor H]` | an ENS name's contenthash, by proof (devnet) |
| `lc --trusted ROOT --fork F --bootstrap FILE … --now SLOT` | the light client, from a checkpoint to an execution block, an ENS name, a contenthash |
| `web SUBJECT ROLE --policy-text JSON5 …` | `claim admit` in a browser page (docs/browser-extension.md) |

Every `tools/*.sh` script is an end-to-end run of part of the above, and its header says what it checks. The site's
demos are those runs, recorded.
