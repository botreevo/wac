# wac-trust

Code pinned by hash, trusted by attestation: [wac design/system/0016](https://git.voltrevo.com/wac.git), built
out as an experiment to see what holds up. The short version of that design: **a hash names bytes, and whatever serves
those bytes is trusted only for serving them.** Whether bytes with a given hash should be installed or run is a separate
question. It is answered by a policy you write, over statements other people sign, some of which are recorded on an
Ethereum chain and read only through storage proofs.

Everything here is wac except three things: the registry contract (Solidity), the wallet that writes to it (ethers,
because publishers and signers use ordinary wallets), and the JavaScript oracles the tests are checked against.

```
wactrust tree DIR | tree --git REPO COMMIT [SUBDIR] | blob FILE      kt1 / kb1 ids
wactrust lock pin | lock check | lock fetch NAME [--from URL]        wac.lock pinned by content
wactrust build … -- COMMAND  |  rebuild STATEMENT --git REPO COMMIT  signed build statements, checked by rebuilding
wactrust review ID SCOPE --key F  |  verify STATEMENT…               reviews; signature checks
wactrust publish MIRROR --blob F --statement S…                      a mirror: a directory or anything served over HTTP
wactrust check ID --policy P --mirror M… [--purpose app|dependency]  may this be used, and why
wactrust resolve NAME@0xPUBLISHER --policy P                         what a name points at, proved
wactrust run NAME@0xPUBLISHER|kb1:… --policy P --mirror M… [-- ARGS] resolve → decide → fetch → hash → run
```

## What was built, and what it showed

**The end-to-end run passes 19 of 19 checks** (`tools/e2e.sh`, on a wacuum devnet). The happy path:

1. Two apps are built from a clean commit: a command-line module, and wac-web's template as one `index.html`.
2. Two independent rebuilders reproduce both byte for byte from a fresh clone, and a reviewer reviews the source.
3. Everything is published to a mirror, and both apps are named on chain with a 20-second change delay.
4. `wactrust run hello@0x…` resolves the name, gathers statements, proves the revocation and deny-list slots, and
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

**Builds reproduced.** Both apps came out byte-identical when rebuilt from a fresh clone in another directory, by two
rebuilders. The first rebuild *failed*, and usefully: `wac build -o dist/hello` does not create `dist/`, and the
publisher's build had only passed because an ignored `dist/` was already on disk. That is exactly what a rebuild is for.

## Findings worth acting on

In the order I would act on them.

1. **wac compiles from a tampered cache without noticing.** `wactrust lock check` refuses a cache entry with one byte
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

## What it does not do

- **The light client is not wired in** (finding 2).
- **wac's own fetch and build do not enforce pins** (finding 1); `wactrust lock check` runs beside them.
- **Stock browsers are not protected.** The page path is `wactrust run` writing checked bytes to open from `file://`.
  A loader page and an extension (0016 H9 options 2 and 3) are not built.
- **Builds were reproduced only on the Node host.** See `docs/` for the wasmtime-host result, if it is there.
- **Signing in wac is for tests and the demo only.** wacuum's secp256k1 says it is not constant-time. Real signers use
  wallets, as `tools/wallet` does.

## Running it

```sh
sh tools/deps.sh                 # the locked wac and wacuum commits into wac's cache, with git
wac test test                    # 23 unit tests
wac build --allow-read --allow-write --allow-run --allow-net --allow-env cmd/wactrust.wac -o dist/wactrust
sh tools/agree.sh ../wac         # one tree, three ways
(cd tools/oracle && npm install) # ethers, js-sha3, solc: the oracles and the wallet
sh tools/e2e.sh /tmp/e2e         # needs wacuum's dist/wacuum.wasm from its experiment branch (WACUUM=…)
```

Dependencies are pinned to experiment branches named `claude/ethereum-wac-package-trust-subwyf`, in wac (adds the `mpt`
and `ethrpc` namespaces) and in wacuum (exports `recover`, pins the same wac, serves `eth_getProof`).

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
