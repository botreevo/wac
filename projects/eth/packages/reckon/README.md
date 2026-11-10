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

```
reckon tree DIR | tree --git REPO COMMIT [SUBDIR] | blob FILE      kt1 / kb1 ids
reckon lock pin | lock check | lock fetch NAME [--from URL]        wac.lock pinned by content
reckon build … -- COMMAND  |  rebuild STATEMENT --git REPO COMMIT  signed build statements, checked by rebuilding
reckon review ID SCOPE --key F  |  verify STATEMENT…               reviews; signature checks
reckon publish MIRROR --blob F --statement S…                      a mirror: a directory or anything served over HTTP
reckon check ID --policy P --mirror M… [--purpose app|dependency]  may this be used, and why
reckon resolve NAME@0xPUBLISHER --policy P                         what a name points at, proved
reckon run NAME@0xPUBLISHER|kb1:… --policy P --mirror M… [-- ARGS] resolve → decide → fetch → hash → run
```

## The second round: attested derivations (2026-11-10)

The model in the explainer is built in parts, beside the first experiment (which is left as it was measured). It is
not wired into wac's own fetch and build: that waits until the design settles.

| | |
| --- | --- |
| `packages/ipfs` | CIDv1, base32, DAG-PB, DAG-CBOR, CAR; UnixFS under `unixfs-v1-2025` (hidden files kept, no symlinks, no modes); a store and resolvers that re-hash every block. Agrees with the JavaScript IPFS implementation, and on the whole wac repository |
| `src/claims.wac` | recipes `{machine, format, input}` and the four statements (Derivation, Endorsement, Rejection, Revocation) as DAG-CBOR objects, signed as EIP-712; byte-identical to ethers and `@ipld/dag-cbor` |
| `src/graph.wac` | the claim index: origins (what derived this?) and dependents (what was derived from it?), saved in a store |
| `src/admit.wac` | admission: a policy of trust roots and per-role rules, applied recursively over the derivation graph, with revocations and rejection lists |
| `src/machine.wac`, `src/world.wac`, `src/canon.wac`, `cmd/derive.wac` | the deterministic WebAssembly machine (`wasm-gc/wac-host/1`) and a runner for it. NaNs are made canonical by rewriting the module, so V8 and wasmtime agree on floats too. `docs/runner.md` has the results; the one gap left is the clock and randomness, which need a change in wac |
| `packages/lightclient`, `packages/ssz` | the light client past Altair, to Fulu and Gloas: per-fork types, execution headers, a fork-aware store, checked against Ethereum's vectors (see its README) |
| `cmd/claim.wac`, `src/policyfile.wac`, `tools/demo.sh` | sign endorsements, rejections and revocations; query origins and dependents; admit under a JSON5 policy. The demo (8 checks): one recipe run on V8 and on wasmtime gives one output, both runners sign, a reviewer endorses the inputs, and the output is admitted only with both witnesses and every endorsement, and refused again when either is revoked |
| `tools/selfbuild.sh` | builds as derivations: wac's compiler, run by the machine, builds an app that runs as the next derivation, admitted only through that chain (the `within` rule takes a file out of a build's output), and the compiler rebuilds itself from source inside the machine, byte for byte, on both engines: a fixed point |
| registry v2 | revocations by (signer, statement CID), rejection lists and delayed names, read by proof; `claim admit --rpc` — [done](docs/registry2.md): 66 of 66 on a devnet |
| `claim publish`, `claim … --mirror`, `tools/claims-mirror.sh` | claims through mirrors ([docs/claims-mirror.md](docs/claims-mirror.md)): a mirror is a store directory holding `claims/index` and the signed blocks, served by any web server; `claim publish DIR` adds the local index to it, and `admit`, `origins` and `dependents` read the local index together with every mirror's (`--mirror DIR` or `http://HOST:PORT`), each signature verified, what fails left out and reported. A mirror can withhold, never forge; a statement any mirror carries counts. 12 checks |
| `cmd/name.wac`, `contracts/DevENS.sol`, `tools/byname.sh` | a name to a decision: an ENS name resolved by proof to a CID, the tree fetched from a mirror (a directory, or HTTP as a trustless gateway) with every block re-hashed, and admitted under a policy. Mainnet half from recorded light-client data (vitalik.eth, from a trusted beacon root); devnet half on contracts with ENS's storage layout, read by the same `packages/ens` code, and anchored only by code hashes since a devnet has no beacon chain. 23 checks |

## The first round: what was built, and what it showed

**The end-to-end run passes 19 of 19 checks** (`tools/e2e.sh`, on a wacuum devnet). The happy path:

1. Two apps are built from a clean commit: a command-line module, and wac-web's template as one `index.html`.
2. Two independent rebuilders reproduce both byte for byte from a fresh clone, and a reviewer reviews the source.
3. Everything is published to a mirror, and both apps are named on chain with a 20-second change delay.
4. `reckon run hello@0x…` resolves the name, gathers statements, proves the revocation and deny-list slots, and
   decides. It then fetches the bytes and checks their hash, and only then spawns the module **holding no authority at
   all**. For the page, it writes the checked bytes out to open from `file://`; the page works there
   (`docs/notes-verified.png`).

Then every attack the design claims to stop, each checked to be refused *for the reason it claims*:

| attack | outcome |
| --- | --- |
| a mirror serving other bytes, first in the list | ignored; the next mirror's correct bytes are used |
| that mirror alone | refused: "served 184016 bytes that do not hash to kb1:…" |
| a statement whose output was edited after signing | refused: signed by some other address than it claims |
| a stranger's build statement making up a quorum | counts for nothing |
| a rebuilder revokes on chain | quorum gone, refused; the other app is unaffected |
| a node that hides storage (answers "empty" with a proof of some other empty slot) | refused: the proof does not hold for that key |
| a deny list you follow adds the web app, then removes it | refused, then allowed |
| the publisher's key is stolen and the name pointed at other code | during the 20 s delay, the old app still runs; afterwards the name has moved, but no rebuilder vouches for the new hash, so refused |
| a name its publisher can move with 0 s notice | not followed (policy `min_delay: 10`) |
| the chain unreachable | refused (`on_stale: 'refuse'`) |
| the registry's address running other code | refused (code hash checked in the account proof) |
| a dependency nobody reviewed / after a review | refused / allowed |

**The tree hash is real and cheap.** On the whole wac repository, hashing a working tree in wac, hashing a commit read
through git (every hash from the bytes, none from git's SHA-1 names), and an independent JavaScript implementation all
agree, in about two seconds on the Node host (`tools/agree.sh`). They also agree on wacuum and wac-ide. The tests also
show that every kind of change moves the hash: one byte, a case-only rename, the executable bit, a file moved, an
empty file added.

**Statements are ethers-compatible byte for byte.** EIP-712 digests match ethers. Because both sides sign with RFC 6979,
wac's secp256k1 signatures (wacuum's) are identical to ethers' for the same key and claim. A statement signed with
MetaMask would verify here.

**Builds reproduced, across hosts too.** Both apps came out byte-identical when rebuilt from a fresh clone in another
directory, by two rebuilders. They also came out byte-identical when built by a `wac` on wasmtime, the host with no
JavaScript in it, as by the one on Node. The first rebuild *failed*, and usefully: `wac build -o dist/hello` does not create `dist/`, and the
publisher's build had only passed because an ignored `dist/` was already on disk. That is exactly what a rebuild is for.

## Findings worth acting on

In the order I would act on them.

1. **wac compiles from a tampered cache without noticing.** `reckon lock check` refuses a cache entry with one byte
   changed. `wac check` and `wac build` happily compile it. wac reads a `wac.lock` carrying `tree` and ignores the field.
   The check belongs inside wac's fetcher and resolver (0016 H2), and `wac update` presumably drops the field when it
   rewrites the lock; I did not test that.
2. **The trust anchor on mainnet is unbuilt.** On the devnet, headers are anchored to the node's own word: every
   storage value below a header is proved, but the header is not. `packages/lightclient` does Altair sync against the
   spec vectors only. It has no mainnet config, fork schedule or live beacon API (its issue 0066), and Electra moves the
   generalized indices it uses. It also lacks the branch from a beacon block to its execution payload's state root.
   Until that exists, "proved" means "proved relative to a header someone gave you".
3. **wacuum did not serve `eth_getProof`.** I added it, on wacuum's experiment branch: `LiveTrie.prove`, checked
   against wac's `packages/mpt` on present and absent keys, before and after mutation. A devnet that cannot prove its
   state can only be believed.
4. **A miscompile in async functions.** In an async function, wacc silently produced wrong behaviour for a loop with a
   `match` (no built statement ever matched its subject). Rewritten with an index, it emitted a module V8 refused:
   *"not enough arguments on the stack for call"*. The same code as an ordinary function is correct, and
   `test/trust_test.wac` pins it. An earlier `for (string path in …)` hit what looks like the same class of bug: the
   checker passes and the emitter types `path` as the array. I could not reduce either; `docs/wacc-cases/` keeps
   the three file versions that trigger them.
5. **The toolchain does not know its own identity.** `install.json5` records no commit or tree, so `toolchain` in a
   build statement was supplied by hand. Two Node-host builds of the `wac` command differed only by an embedded
   `mktemp` path (`/tmp/tmp.XXXX/asm/…` in source comments). Normalise that and the command is reproducible. Also, a
   toolchain named by the *whole* wac tree changes whenever any file in it changes (here, `lib.wac`), even when the
   compiler is byte-identical. Name the toolchain by the compiler module's kb1, or by the subtree that builds it.
6. **An outside project cannot reach `mpt` or `ethrpc`.** They are not in wac's `lib.wac`, and wacuum's `recover` was
   not exported. All three are fixed on branches. Two copies of wac's library (one per dependency) put a program past
   wacc's 512-file limit, because even `crypto.hmacSha256` reaches about 300 files, so every dependency had to share
   one wac pin.
7. **A statement's id is the claim, not the signer.** Two rebuilders signing the same claim produce the same EIP-712
   digest. Revocation is therefore keyed by `(signer, id)`, as the contract does, and must stay that way.
8. **wac.lock's cache mixes bookkeeping with content.** A cache entry holds the files plus a `pack.pack` marker, so a
   tree hash of the entry must skip a top-level `pack.pack`. A repository containing a real top-level `pack.pack`
   would be misread. 0016's `cache/tree/<hash>/` layout removes the ambiguity.

## Registry v2

`contracts/Registry.sol` and `src/registry2.wac` are the registry rebuilt for this design. Objects are named by CID.
Revocations are keyed by (signer, statement CID) and can also be relayed as signed EIP-712 Revocations. Rejection
lists hold a reason hash. Names point at a CID, and changes to the CID or to the delay itself both wait out the
delay. The reader proves every question admission could ask and turns the answers into admit's `Chain`. Its
end-to-end run on a devnet passes 66 of 66 checks, including a lying node and a wrong code hash. `claim admit
… --rpc HOST:PORT --registry ADDR --code-hash H` uses it in place of `Chain.none()`. What was built, the
layout, and the findings (wacuum drops revert data, among others) are in [docs/registry2.md](docs/registry2.md).

## What it does not do

- **The light client is not wired in** (finding 2).
- **wac's own fetch and build do not enforce pins** (finding 1); `reckon lock check` runs beside them.
- **Stock browsers are not protected.** The page path is `reckon run` writing checked bytes to open from `file://`.
  A loader page and an extension (0016 H9 options 2 and 3) are not built.
- **Reproduction was measured on two hosts (Node, wasmtime) on one machine**, not on several machines or the V8 host.
- **Signing in wac is for tests and the demo only.** wacuum's secp256k1 says it is not constant-time. Real signers use
  wallets, as `tools/wallet` does.

## Running it

From wac-eth's root, with `wac` built and `sh tools/deps.sh` run as its README says:

```sh
wac task reckon:test                         # 23 unit tests
wac task reckon:build                        # packages/reckon/dist/reckon.wasm
sh packages/reckon/tools/agree.sh ../wac              # one tree hashed three ways, on any git repository
(cd packages/reckon/tools/oracle && npm install)      # ethers, js-sha3, solc: the oracles and the wallet
(cd packages/wacuum && wac build --allow-read --allow-write --allow-net cmd/wacuum.wac -o dist/wacuum)
TOOLCHAIN=kt1:… sh packages/reckon/tools/e2e.sh /tmp/e2e   # the whole run on a devnet; needs a clean commit
sh packages/reckon/tools/registry2.sh /tmp/r2             # the registry v2 on a devnet: 66 checks
sh packages/reckon/tools/byname.sh /tmp/bn                 # ENS name → proven CID → fetched tree → admission: 23 checks
```

`mpt`, `ethrpc` and wacuum's secp256k1 come from `@/lib.wac`, and the devnet the end-to-end run uses is the wacuum beside
this. The example apps under `examples/` are projects of their own on purpose: a build statement covers a source tree
with its own pinned dependencies. `docs/report.html`, `docs/e2e-run.txt` and `docs/wacc-cases/` are records of runs made
under the old name, and keep it.

| | |
| --- | --- |
| `src/tree.wac`, `src/walk.wac` | kt1/kb1; hashing a directory or a commit |
| `src/lock.wac` | `tree`/`root` in wac.lock: pin, check, verified fetch |
| `src/statement.wac` | EIP-712 built/reviewed statements, sign and verify, file form |
| `src/build.wac` | build from a clean commit; rebuild and compare |
| `src/policy.wac` | `trust.json5` and the pure decision function |
| `src/registry.wac` | the contract's storage layout, read by proof |
| `src/trust.wac` | mirrors, the chain's answers for a decision, name resolution |
| `contracts/TrustRegistry.sol` | revocations, deny lists, delayed names: all storage, no admin |
| `tools/e2e.sh`, `tools/liar.mjs` | the whole run, and a node that hides storage |
