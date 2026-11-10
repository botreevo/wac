# reckon

**Attested derivations**: every result named by its hash, statements about how each was produced and whether it is
acceptable, and a policy you own that reckons with both. [Design 0016](../../design/system/0016-code-pinned-by-hash-and-trusted-by-attestation.md)
is where it started; this package is the experiment that built that design end to end. It was the wac-trust
repository until 2026-11-10, and its history came with it.

**The code is the experiment, and the design has moved past it.** What it calls a build statement is one special case of
a *derivation*: a *machine* (a fixed rule, such as a deterministic WebAssembly profile) applied to one input tree gives one
output tree, and the program is just one object in the input. Objects are to be IPFS CIDs under the `unixfs-v1-2025`
profile (hidden files included, no symlinks, no permissions) rather than the `kt1`/`kb1` Keccak trees here, and a recipe
names its machine and object format so both can change. The explainer, *Attested derivations*, has the model and its
terms; the code below is what was measured.

The short version that still holds: **a hash names bytes, and whatever serves those bytes is trusted only for serving
them.** Whether bytes with a given hash should be installed or run is a separate question, answered by a policy you
write over statements other people sign, some of them recorded on an Ethereum chain and read only through storage
proofs.

Everything here is wac except three things: the registry contract (Solidity), the wallet that writes to it (ethers,
because publishers and signers use ordinary wallets), and the JavaScript oracles the tests are checked against.

**The first round is deleted** (decision J, docs/decisions/J-v1-code.md), now that `claim run` and `deps` do the
two things only it did. Its code, its measured results and its findings are in the history: `packages/reckon/v1/`
and `v1/README.md` at commit 2a2241d, or `packages/reckon/` before it.

## The second round: attested derivations (2026-11-10)

The model in the explainer is built in parts, beside the first experiment (which is left as it was measured). It is
not wired into wac's own fetch and build: that waits until the design settles.

| | |
| --- | --- |
| `packages/ipfs` | CIDv1, base32, DAG-PB, DAG-CBOR, CAR; UnixFS under `unixfs-v1-2025` (hidden files kept, no symlinks, no modes); a store and resolvers that re-hash every block. Agrees with the JavaScript IPFS implementation, and on the whole wac repository |
| `src/claims.wac` | recipes `{machine, format, input}` and the four statements (Derivation, Endorsement, Rejection, Revocation) as DAG-CBOR objects, signed as EIP-712; byte-identical to ethers and `@ipld/dag-cbor` |
| `src/graph.wac` | the claim index: origins (what derived this?) and dependents (what was derived from it?), saved in a store |
| `src/admit.wac` | admission: a policy of trust roots and per-role rules, applied recursively over the derivation graph, with revocations and rejection lists |
| `src/machine.wac`, `src/world.wac`, `src/canon.wac`, `cmd/derive.wac` | the deterministic WebAssembly machine (`wasm-gc/wac-host/2`) and a runner for it. NaNs are made canonical by rewriting the module, and the program runs sealed (no clock, no random bytes), so V8 and wasmtime agree on every program in the corpus. `docs/runner.md` has the results |
| `packages/lightclient`, `packages/ssz` | the light client past Altair, to Fulu and Gloas: per-fork types, execution headers, a fork-aware store, checked against Ethereum's vectors (see its README) |
| `cmd/claim.wac`, `src/policyfile.wac`, `tools/demo.sh` | sign endorsements, rejections and revocations; query origins and dependents; admit under a JSON5 policy. The demo (8 checks): one recipe run on V8 and on wasmtime gives one output, both runners sign, a reviewer endorses the inputs, and the output is admitted only with both witnesses and every endorsement, and refused again when either is revoked |
| `tools/selfbuild.sh` | builds as derivations: wac's compiler, run by the machine, builds an app that runs as the next derivation, admitted only through that chain (the `within` rule takes a file out of a build's output), and the compiler rebuilds itself from source inside the machine, byte for byte, on both engines: a fixed point |
| registry v2 | revocations by (signer, statement CID), rejection lists and delayed names, read by proof; `claim admit --rpc` — [done](docs/registry2.md): 73 of 73 on a devnet, a `name:NAME@0xPUB` subject among them |
| `claim publish`, `claim … --mirror`, `tools/claims-mirror.sh` | claims through mirrors ([docs/claims-mirror.md](docs/claims-mirror.md)): a mirror is a store directory holding `claims/index` and the signed blocks, served by any web server; `claim publish DIR` adds the local index to it, and `admit`, `origins` and `dependents` read the local index together with every mirror's (`--mirror DIR` or `http://HOST:PORT`), each signature verified, what fails left out and reported. A mirror can withhold, never forge; a statement any mirror carries counts. 12 checks |
| `cmd/name.wac`, `contracts/DevENS.sol`, `tools/byname.sh` | a name to a decision: an ENS name resolved by proof to a CID, the tree fetched from a mirror (a directory, or HTTP as a trustless gateway) with every block re-hashed, and admitted under a policy. Mainnet half from recorded light-client data (vitalik.eth, from a trusted beacon root); devnet half on contracts with ENS's storage layout, read by the same `packages/ens` code, and anchored only by code hashes since a devnet has no beacon chain. 23 checks |
| `--anchor`, `tools/replay.mjs`, `tools/anchor.sh` | chain reads anchored by the light client ([docs/anchoring.md](docs/anchoring.md)): `--anchor BLOCKHASH` fixes the header by its hash and every proof to its state root, so the checkpoint `lc` starts from is the only trust root left. Offline on recorded mainnet data, vitalik.eth resolves through a replaying node, anchored to the block lc proves, to lc's own CID, and a node that swaps the header or a proof is refused; on a devnet, an anchored `claim admit` reads the anchored block's state and no other. 13 checks |
| `claim admit … --checkpoint`, `src/checkpoint.wac`, `src/names.wac`, `tools/admit-by-name.sh` | one command for admission ([docs/admit.md](docs/admit.md)): `claim admit ens:NAME ROLE --policy P --checkpoint ROOT --beacon DIR --rpc NODE [--registry …] [--mirror …]` runs the light client from the checkpoint (over beacon data in a directory or fetched live with `--beacon-url`) to an anchor, reads the name by proof at it, the registry's revocations and rejections too, then the claims here and in every mirror, and decides; a step asked for that cannot be done refuses. Offline on recorded mainnet data, vitalik.eth is admitted under a reviewer's endorsement, and another checkpoint, a lying execution or beacon node and an unknown name are refused; a policy's `names` decides whether an ENS name is followed at all ([docs/admit.md](docs/admit.md#which-names-are-followed)); and `--state` keeps the light client's state, so the next run resumes from it with no checkpoint and no bootstrap, refused when it is too old or cannot be continued. 40 checks |
| `claim run`, `tools/run.sh` | admit, then fetch and run, in one command ([docs/admit.md](docs/admit.md#claim-run)): the admitted object's blocks, from the store or a mirror, each checked against its CID, run as the machine runs a derivation (sealed, canonical NaNs, its tree read-only at `/in`, an `/out` dropped at the end, no network or environment), its stdout and exit code the command's; `--out` writes the bytes or the tree instead; mirrors over HTTPS too. Not admitted, or bytes that do not hash: nothing runs. 17 checks |
| `cmd/deps.wac`, `src/deplock.wac`, `tools/deps-lock.sh` | dependencies pinned by CID ([docs/lock.md](docs/lock.md)): each `wac.lock` entry gains `cid`, the commit tree's root (the package cache's checkout less its `pack.pack` marker, which is the same CID `obj add-git` gives). `deps pin`, `check` (refuses a changed cache or an unpinned entry), `fetch` (by CID from a mirror, or `--git`; installed only if it is the pin) and `admit ROLE` (each locked CID under a policy). 14 checks |
| `src/admission.wac`, `cmd/web.wac`, `tools/browser-admit.sh` | admission as a library, which `claim admit` and `claim run` are now thin over, and a browser entry over it: milestone 1 of [docs/browser-extension.md](docs/browser-extension.md). `web` admits ens:vitalik.eth on the command line, as claim does, and built with wac's `--target browser`, in headless Chromium too: the light client, the name by proof, the claims and the decision in the page, its HTTP the browser's fetch, and every tampered answer refused. With `--out` it writes the admitted tree to the browser's storage, and with `--state` keeps the light client's state there, the next page resuming from it. 12 checks |
| `tools/capstone.sh`, [docs/capstone.md](docs/capstone.md) | **the motivating case, end to end**: source → a compiler built by the seed inside the machine → the app it builds → its run, each a derivation two runners on two engines sign; claims published to a mirror; a name pointing at the app; and a fresh client with an empty store that resolves the name by proof, takes the claims from the mirror, fetches and checks the bytes, admits and runs it, then refuses a tampered output, a missing endorsement, a lying mirror and a revoked runner. The doc lists what is still trusted or stubbed |
| `tools/ladder.sh`, [docs/bootstrap-derivations.md](docs/bootstrap-derivations.md) | decision D, rooting trust at reviewed sources instead of the seed binary. The plan, and its first milestone: wac's hand-written bootstrap ladder builds the compiler, and inside the machine it compiles wac to the same output tree, one CID on V8 and wasmtime, as the seed does. Two unrelated origins for one compiler. 6 checks |
| `cmd/boot.wac`, `src/boot.wac`, `tools/l0.sh`, [docs/l0-machine.md](docs/l0-machine.md) | decision D, milestone 2: wac-L0 as a machine, `wac-l0/1`, whose rule is wac's written `bootstrap/spec/l0.md` (pinned by CID) and whose two runners are wac's Rust and JavaScript assemblers, each signing. They agree on every L0 text wac's tests hold, the L1 interpreter, and wacc's 7.8 MB of L0; the interpreter is admitted only through both runners and a reviewed source. 20 checks (21 with LADDER) |
| `tools/flatten.sh`, [docs/flatten-machine.md](docs/flatten-machine.md) | decision D: the flattener as a machine, `wac-flatten/1`. wac-L5 ignores `import`, so the bootstrap flattens a module graph into one program; its two runners are wac's JavaScript and Rust flatteners, each signing. They agree on wacc's 38 modules (the same 3.7 MB the ladder makes) and on a bare-specifier fixture; flattened wacc is admitted only through both runners and a reviewed source. 9 checks |
| `site/`, `tools/site.sh` | the pages site, https://pages.voltrevo.com/wac-eth/: what reckon is, how it works, what is still trusted, and the demos as recorded runs (`--record` runs them again; `--publish` pushes the `pages` branch) |

## Registry v2

`contracts/Registry.sol` and `src/registry2.wac` are the registry rebuilt for this design. Objects are named by CID.
Revocations are keyed by (signer, statement CID) and can also be relayed as signed EIP-712 Revocations. Rejection
lists hold a reason hash. Names point at a CID, and changes to the CID or to the delay itself both wait out the
delay. The reader proves every question admission could ask and turns the answers into admit's `Chain`. Its
end-to-end run on a devnet passes 73 of 73 checks, including a lying node and a wrong code hash. `claim admit
… --rpc HOST:PORT --registry ADDR --code-hash H` uses it in place of `Chain.none()`. What was built, the
layout, and the findings (wacuum drops revert data, among others) are in [docs/registry2.md](docs/registry2.md).

## Running it

From wac-eth's root, with `wac` built and `sh tools/deps.sh` run as its README says:

```sh
sh packages/reckon/tools/run.sh /tmp/run                 # claim run: 17 checks
sh packages/reckon/tools/deps-lock.sh /tmp/dl             # wac.lock pinned by CID: 14 checks
wac task reckon:test                         # the unit tests, v2's and then v1's
(cd packages/reckon/tools/oracle && npm install)      # ethers, js-sha3, solc: the oracles and the wallet
sh packages/reckon/tools/registry2.sh /tmp/r2             # the registry v2 on a devnet: 73 checks
sh packages/reckon/tools/byname.sh /tmp/bn                 # ENS name → proven CID → fetched tree → admission: 23 checks
```
