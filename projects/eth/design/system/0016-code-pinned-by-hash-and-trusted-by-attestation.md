# 0016 — code pinned by hash, trusted by attestation: Ethereum as the record, git as a locator

- **Status:** proposal; built out as an experiment 2026-11-08 —
  [wac-trust](https://git.voltrevo.com/wac-trust.git), whose README has every result. See *What the experiment showed*
- **Opened:** 2026-11-08
- **Written by:** Claude, from a conversation with the operator: *"use Ethereum as source of truth for wac
  packages. Pin code with hash and use git/etc as a way to resolve those hashes only. This is for package
  management but also for built apps. Attestations can link app source to the code that should run, and a
  user can configure trust in attestors and revocation lists. Web apps are an important use case."*
- **Answers:** [0003](0003-an-ethereum-centric-reference-distribution.md)'s open piece *"content-addressed
  retrieval — needs a decision about what is being promised"*, and the update channel it names
- **Builds on:** wac's `design/lang/0009`
  D8, D10, D11 — locked Git imports, which this changes from *locked by commit* to *locked by content*

## What is promised

One sentence, because 0003 asked for exactly this decision: **a hash names bytes, and nothing that serves
those bytes is trusted for anything but serving them.** Whether bytes with a given hash *should* be used —
installed as a dependency, run as an app — is a separate question, answered by a policy the user writes over
statements other people sign, some of which are recorded on the Ethereum chain.

That splits into three layers, and the split is the design:

| layer | what it is | where it lives | trusted for |
| --- | --- | --- | --- |
| **identity** | the hash of a source tree or a built artefact | nowhere — it is computed | nothing; it is checked |
| **naming** | a name or channel pointing at a hash | a contract or an ENS record the user chose | what the publisher currently says, delayed (H8) |
| **trust** | statements about hashes — *built to*, *reviewed*, *revoked*, *deny* — and the user's policy over them | signed statements; revocations on the chain; the policy on the user's disk | whatever the policy grants each signer |

Git, HTTP mirrors, IPFS, a USB stick and `$WAC_HOME`'s cache are all the same thing in this picture: places
bytes might be found. An ordinary node answering `eth_getProof` is the same again — `packages/ethrpc`'s README
already says it is trusted for availability and for nothing it says.

## What we are aiming at

- `wac.lock` pins every dependency by a content hash; a fetch that does not hash to it is refused, wherever it
  came from, and the cache is keyed by that hash rather than by repository and commit.
- A build can say what it was: these sources, this toolchain, these arguments, this output — and anyone can
  rebuild and check, so an attestation that a source becomes an artefact is a claim with an oracle.
- A user writes down whom they believe: which signers, how many must agree, which deny lists they follow, how
  stale a revocation check may be. Installing a dependency and running an app both go through it.
- A web app is one `index.html` (wac-web already builds that) named by its hash, fetched from anywhere,
  checked before it runs, and refused if a signer the user follows has revoked it.
- None of the first three needs the Ethereum chain. The chain is the shared, ordered, censorship-resistant
  record of the statements that have to be *current* — names and revocations — and it is read through
  `packages/lightclient` and `packages/mpt`, not through somebody's word.

## Decisions proposed

These are proposals until the operator rules; each has its reason so that ruling against one is a decision
about the reason.

### H1 — identity is a keccak256 Merkle tree of files, not a git commit

A commit is the wrong thing to attest to, three ways. It is SHA-1, and `packages/git` hashes with plain
SHA-1 rather than git's collision-detecting variant (0005 says so), so a signature over one inherits a
collision attack. It covers author, dates and history, so the same files at two commits are two identities and
a rebase invalidates every attestation. And it is a fact about one repository, where the claim we want is
about files.

So the identity of a source tree is computed over its files only:

```
leaf(content)  = keccak256(0x00 || content)
node(entries)  = keccak256(0x01 || entry*)        entries sorted by name, bytewise
entry          = u16be(len(name)) || name || kind || hash
kind           = 0x00 file  |  0x01 executable file  |  0x02 directory
```

written `kt1:<64 hex>` for a tree and `kb1:<64 hex>` for a single file (its leaf). The `0x00`/`0x01` prefixes
keep a file from being mistaken for a directory. A name is UTF-8, non-empty, with no `/`, and is neither `.`
nor `..`. The executable bit is in because git's two regular-file modes are, and 0005 made it round-trip.

**Refused, not hashed:** symlinks, whose rule is still undecided (wac's `issues/system/0137`),
and gitlinks. A dependency containing either cannot be pinned until there is a rule, which is better than a
rule nobody chose.

**keccak256 because it is the hash the chain checks for free** — an opcode, so a contract can check a proof
about a tree for the gas of a few hashes — and `crypto.keccak256` exists and runs at 260 MB/s. The `1` in
`kt1` is the version. A later version can change the algorithm, so nothing has to bet on keccak forever.

**A tree rather than a hash of an archive** because a `subdir` mapping takes one directory, and 0009 D7
already confines its code to that directory. Its subtree's hash covers exactly what it can reach, and a proof
from the root down to it is one path of sibling hashes. An archive would mean fetching and hashing everything
to check anything.

Rejected: **git's SHA-256 object format**, which would let a git server look objects up by our hash directly.
`packages/git` deliberately does not speak it (0005, *"interoperating means the default"*), most hosts do
not serve it, and it still hashes git's tree encoding, mode strings included. **sha256 everywhere**, which
would let a browser's Subresource Integrity check a script (SRI accepts sha256, sha384 and sha512, not
keccak). That check helps only a page that has already been trusted, and H9 does not rely on one.

### H2 — the lockfile's hash is authoritative; `git` and `commit` become a locator

```json5
web: { git: 'https://github.com/voltrevo/wac-web.git', ref: '6ff6b30e…', commit: '6ff6b30e…',
       tree: 'kt1:…' }
```

`tree` is what the build depends on. `git` and `commit` are where to try first. A fetch whose recomputed
`tree` differs is a **refusal**, never an update, the same rule 0009 D10 already applies to a branch that
moved. For a `subdir` mapping `tree` is the subtree's hash, and the lock also records `root`, the hash of the
whole repository, so that D8's rule survives: identity is still one canonical name plus a path, now
`(root, repository-relative path)` instead of `(repository, commit, path)`.

The cache becomes `$WAC_HOME/cache/tree/<hash>/`. It holds files whose hash was checked when they were
written, and nothing about where they came from.

**Transitive pinning comes for free.** A dependency's own `wac.lock` is a file inside its tree, so the root
hash of an app covers every dependency's hash, and theirs. One hash pins the whole graph, and one attestation
can cover it.

A local checkout used in place of a locked dependency (`tools/dev-link.sh` in wac-kps, `tools/use-local-wac.sh`
in wacuum) stays possible, but it becomes an explicit override the build reports. A tree whose hash does not
match the lock is never quietly substituted.

### H3 — a build says what it was

`wac build` can write a **build statement**:

```json5
{ source: 'kt1:…', dir: 'examples/notes', command: ['wac', 'run', '--allow-read', 'build.wac', 'src/app.wac', 'dist'],
  path: 'dist/index.html', toolchain: 'kt1:…', output: 'kb1:…' }
```

*(The experiment's shape: "in source tree `source`, in its directory `dir`, running `command` writes `path`, whose
hash is `output`". The first draft had `entry` and `args`, which cannot say where to run or what file is the output.)*

`toolchain` is the hash of the wac tree the compiler was built from. That is the right name because
`./bootstrap.sh` builds it from source through the ladder, and refuses a compiler that does not rebuild
itself byte for byte (0009 D2). So a toolchain hash names one compiler, not a family of binaries.

**This is only worth signing if builds reproduce,** and that is measured, not assumed: step 3 below builds
the same statement on two hosts and compares. The compiler's fixpoint is evidence that the compiler is
deterministic. It is not evidence that every builder is (the page builder inlines a driver, the TypeScript
bundler emits JavaScript), so where outputs differ, the difference gets found and fixed. If a builder cannot
be made to reproduce, its statements say so, and a policy can refuse it.

### H4 — four kinds of statement, signed with Ethereum keys

| statement | says | oracle |
| --- | --- | --- |
| **built** | `Built(bytes32 source,string dir,string[] command,string path,bytes32 toolchain,bytes32 output)` reproduced for me | rebuilding |
| **reviewed** | I read source `kt1:…`, to this scope | none; that is why it is separate |
| **revoked** | my earlier statement `id` no longer stands | — |
| **deny** | do not run or install `kt1:…`/`kb1:…`, for this reason | — |

Statements are EIP-712 typed data, signed by an ordinary Ethereum account. That way the same bytes are valid
offchain, in a file next to a release, and onchain, given to a contract, and anyone can sign with an existing
wallet.

**wac only verifies.** Checking a signature means recovering the signer's address, which wacuum already does
(about 150 µs per signature, with secp256k1's own field arithmetic). Signing with a secret key is the risk
class 0003 gates separately, and nothing here needs it. The recovery code moves from wacuum into a wac
package, since that is now a second user of it.

### H5 — the policy is a file the user owns, and knows nothing about Ethereum

```json5
// $WAC_HOME/trust.json5
{
  signers: { alice: '0x…', rebuild1: '0x…', rebuild2: '0x…', ci: '0x…' },
  deny: ['denylist-a'],                       // a source of deny statements, defined below
  rules: [
    { for: 'dependency', require: { built: { of: ['rebuild1', 'rebuild2', 'ci'], at_least: 2 } } },
    { for: 'app',        require: { built: { at_least: 2 }, reviewed: { of: ['alice'] } } },
  ],
  freshness: { revocations: '24h', on_stale: 'refuse' },
}
```

The engine is a pure function: given statements, a policy, a hash and what it is for, it answers *allowed*,
or *refused* with the rule that refused it. Where the statements come from (files, a contract, a mirror) is a
provider behind it. This is how 0003's E2 holds: the toolchain sees hashes, statements and a policy. The
Ethereum backend is one provider, and the only Ethereum-shaped parts the core sees are the signature scheme
and an address format.

**`on_stale` is the user's choice, and the shipped default is `refuse`.** Failing open means a user who goes
offline, or a network that drops them, gets revoked code. Failing closed means an app will not start
without a recent check. Both are defensible, so the file says which one it is rather than the code.

### H6 — revocations and deny lists are contract storage, so their absence is provable

"This statement has not been revoked" is a claim about something missing. `packages/mpt` already proves
absence from a storage trie: a proof for a slot holding zero, against a storage root taken from an account
proof, against a state root from a finalized header. Absence of an *event* has no such proof short of reading
every receipt. So a revocation is a write to `revoked[statementId]`, and a deny list is a write to
`denied[list][hash]`, each in a mapping whose slot `packages/ens/src/verified.wac` already knows how to
derive.

Events are still emitted, so watchers and indexers can follow along. They are never what a check reads.

**Freshness is a header's timestamp.** The proof is against a finalized beacon block the light client
verified, so "checked within 24h" can be checked too, not just believed.

### H7 — names are ENS records or a registry contract, never something the core resolves

A name is how a person asks for an app and how a dependency follows a channel. Two candidates, to be chosen:

- **ENS contenthash.** It exists, wallets and gateways read it, and `packages/ens` already builds the call
  and resolves the registry half with proofs. But a contenthash names its codec from the multicodec table,
  which has no entry for `kt1`, and the resolver's own storage is not yet verified (0003's state of play).
- **A registry contract of our own,** `name → (hash, effective_from)`, with H8 built in.

Either way, `wac.json5` can name a dependency by channel instead of by git URL. The lock still records the
hash it resolved to, and `wac update` is still the only thing that moves it (0009 D10).

### H8 — following a channel is the dangerous path, so it is slow and needs agreement

If a publisher's key is stolen, the name moves to whatever the thief built. Two defences, both cheap, both on
by default for anything followed automatically:

- **A delay.** A pointer change takes effect `delay` after it is recorded, and the change is visible
  immediately. That gives the publisher, watchers and deny-list maintainers a window to object.
- **Agreement.** The new hash is followed only once the policy's `built` rule (and any `reviewed` rule) is met
  for it. A stolen publisher key alone moves nothing.

A user can drop either one for a channel they trust. The defaults are what a stranger gets.

### H9 — a web app is checked by something the user controls, before it runs

**A stock browser opening `https://app.example` runs whatever that server sends,** and no statement on any
chain changes that. So the check lives in a host that runs before the app does, in this order of strength:

1. **The wac hosts themselves:** `wac run <name or hash>` on the command line, and wac-desktop / Wacland. Each
   resolves the name through proofs, fetches the bytes from anywhere (`packages/fetch`, git, the cache),
   checks the hash, asks the policy, and only then instantiates. 0015 left out *"no module from the network:
   fetching is a separate capability"*. This adds that capability, with one rule: bytes from the network are
   instantiated only under the hash the policy allowed.
2. **A loader page, pinned by being opened from `file://`.** wac-web builds pages that work from `file://`,
   so a small loader the user saved once can do (1) inside a browser. The loader is the one thing trusted on
   first use, and it is small and has its own hash.
3. **A browser extension,** later, which can do (1) for any page.

Rejected as a guarantee: **a service worker** that pins an app after its first load. The first load is
trusted on faith, and browsers re-check a service worker's own script on their own schedule. It can be
offered as a convenience; this design does not claim it protects anyone.

**Apps that load code at runtime** (`load`, spawn of bytes) go through the same check, so an allowed app
cannot fetch an unallowed module and run it.

## What the experiment showed

All six steps of the order of work were built, as a separate project
([wac-trust](https://git.voltrevo.com/wac-trust.git)) and two experiment branches: here, `lib.wac` gains `mpt`
and `ethrpc`; in wacuum, `recover` is exported and `eth_getProof` is served. An end-to-end run on a wacuum devnet
passes 19 of 19 checks. Two apps (a module, and wac-web's template as one page) are built, rebuilt byte for byte by
two rebuilders from a fresh clone, reviewed, published to a mirror, named with a delay, and run. Then each attack
H1–H9 claims to stop is made, and each is refused for the reason it claims. The decisions held. What changed or
was learned:

- **H1 holds and is cheap.** Working tree, commit through git, and an independent JavaScript oracle agree on this
  whole repository in about two seconds on the Node host. Vectors: `leaf("")` = `bc36789e…bcc98a`, the empty tree =
  `5fe7f977…dcffd2` (the full set is in wac-trust's `test/tree_test.wac`).
- **H2 cannot be enforced from outside wac.** wac reads a lock with `tree` and ignores it, and compiles from a cache
  entry with one byte changed; only an outside `wactrust lock check` refuses it. The check has to move into the
  fetcher and resolver.
- **H3: builds reproduced, on the Node and wasmtime hosts alike, and the first rebuild found a real problem.** The publisher's build
  depended on an ignored `dist/` that only the publisher had. The toolchain does not record its own identity, two
  builds of the command differ only by an embedded temporary path, and naming the toolchain by the whole tree is
  too coarse (it moved when only `lib.wac` changed). Name it by the compiler module's kb1 instead.
- **H4: statements are ethers-compatible byte for byte**, signatures included (RFC 6979 on both sides). Identical
  claims by two signers have one id, so revocation must stay keyed by (signer, id).
- **H6 works as designed**, once the node can prove. A node answering "empty" with a sound proof of another empty
  slot is refused. wacuum had no `eth_getProof`, and the experiment added it.
- **H8's delay plus agreement stops a stolen publisher key.** The name moves after the delay, and nothing runs,
  because no rebuilder vouches for the new hash.
- **The anchor is the gap.** On the devnet the header is the node's word; everything below it is proved.
  `packages/lightclient` is Altair-only with no live beacon API (its issue 0066), and Electra moves its indices.
  This is the piece that turns "proved" into "proved against consensus", and it is now the critical path.
- **wacc miscompiled async code here twice**; the cases are in wac-trust's `docs/wacc-cases/`.

## Explicitly not this

- **Code does not go onchain.** Hashes, pointers, revocations and (optionally) statements do. 0003 said
  *binaries do not go onchain*, and this extends that to source.
- **No canonical registry, signer, deny list or chain.** The policy names its own. A fork of the registry
  contract is a line in the user's file.
- **The Ethereum chain is not needed to pin.** H1–H3 and H5 work offline and with no contract anywhere. What
  needs the chain is *currency*: the latest name, and whether anything was revoked since.
- **Not keeping bytes available.** A hash says what the bytes must be, not that anyone still has them.
  Mirrors are a separate concern, and a lock with several locators is the most this design does about it.
- **Not a version solver.** 0009's per-mapping locks stand. A channel is a pointer, not a range.
- **Not protection for apps served to stock browsers over HTTPS** (H9).

## Open questions for the operator

1. **L1 or an L2** for the registry and the revocations. L1 is what `packages/lightclient` and `packages/mpt`
   verify today. An L2 is far cheaper per write but needs one more proof, from the L2's state to L1, which is
   a real piece of work per rollup.
2. **EAS or contracts of our own.** The Ethereum Attestation Service has schemas, revocation, and offchain
   EIP-712 attestations, and indexers already read it. What has to be checked is whether H6's two questions
   ("is statement X revoked", "has list L denied hash H") are each one storage slot in its layout. If they
   are not, a small contract of our own is simpler than proving around EAS.
3. **ENS contenthash or our own registry** (H7). This depends on whether a `kt1` codec can be registered, and
   on when the resolver's storage gets verified.
4. **The default for `on_stale`** (H5). Proposed: `refuse`.
5. **Where secp256k1 recovery lives** (H4). Proposed: a `packages/secp256k1`, verification only, moved out of
   wacuum.

## Order of work

Each step is useful if the ones after it never happen. The chain comes fifth on purpose.

1. **The tree hash.** `kt1`/`kb1` in a package, with `wac tree hash <dir>`. There is no outside oracle for a
   format we define, so the evidence is agreement and sensitivity:
   - the same hash from a working tree, from a commit read through `packages/git` (loose and packed), and
     from a checkout made by `gitco`, on this repository;
   - a different hash for every single-byte change, rename, executable-bit flip and moved file in a fixture;
   - test vectors written into this document once fixed.

   *Done when* this repository's tree hashes the same all three ways and the perturbation test cannot be
   passed by a hash that ignores names or modes.
2. **`tree` in `wac.lock`.** `wac update` and `tools/fill-cache.sh` write it, every fetch checks it, and the
   cache moves to `cache/tree/<hash>/`. *Done when* a remote serving the right commit with one changed file is
   refused with the expected and actual hashes, a tampered cache entry is refused rather than used, and this
   repository's pin of `web` carries a `tree`.
3. **Build statements, and rebuilding.** `wac build --statement`, and `wac rebuild <statement>`, which
   answers *same* or the first differing byte. *Done when* the site's pages and a package example produce the
   same statement on the Node host and on wasmtime, or the difference is found and fixed. The first failure
   is the useful output of this step.
4. **Statements and the policy engine, still offline.** EIP-712 statements, `packages/secp256k1` for
   recovery, `trust.json5`, and the engine over statements read from files. *Done when* a fixture set of
   statements and policies is answered correctly in both directions, including a statement whose signature
   recovers to the wrong signer and a quorum of two from the same signer twice.
5. **The chain backend.** Answer questions 1–3. Then deploy the registry and revocation contracts on
   [wacuum-devnet](https://git.voltrevo.com/wacuum-devnet.git), which runs wacuum and serves `eth_getProof`.
   It is a chain we control with an execution client written in wac, so the whole loop is ours to test.
   Reads go through `packages/ethrpc` for availability and `packages/mpt` for truth. *Done when* `wac update`
   follows a channel on the devnet, refuses a revoked hash with a proof that it was revoked, accepts an
   unrevoked one with a proof that the slot is empty, and waits out H8's delay.
6. **The loader.** `wac run <name|hash>`, then wac-desktop, then the `file://` loader page. *Done when* an app
   published on the devnet runs from a mirror that is not where it was published, the same app from a
   tampered mirror is refused, and after a revocation it is refused within the policy's freshness window.

Step 5 has one prerequisite to check first: that `packages/lightclient` follows a live chain's current
forks, not just the Altair fixtures 0003 records. For the devnet, a trusted genesis can stand in while that
is checked.

## State of play

| piece | state |
| --- | --- |
| keccak256 | **done**: `crypto.keccak256` (0003) |
| reading git trees and blobs, loose and packed | **done**: `packages/git` (0005) |
| locked imports, per-mapping locks | **done**: `packages/wacpkg`, `wac.lock` (0009 D10) |
| a reproducible compiler | **done**: the fixpoint in `./bootstrap.sh` (0009 D2) |
| the tree hash (step 1) | **built in wac-trust**: `src/tree.wac`, three-way agreement on this repository |
| `tree` in `wac.lock` (step 2) | **built beside wac**: `wactrust lock pin/check/fetch`; **not** in wac's own fetcher, which ignores the field |
| build statements and rebuilding (step 3) | **built**: `wactrust build/rebuild`; two apps reproduce from a fresh clone, byte-identical on the Node and wasmtime hosts |
| secp256k1 recovery | **done in wacuum**, exported on its experiment branch; not yet a wac package |
| statements and policy engine (step 4) | **built**: EIP-712 statements agreeing with ethers; `src/policy.wac`, eleven cases |
| storage proofs, inclusion and absence | **done**: `packages/mpt`, `packages/ens/src/verified.wac` (0003) |
| beacon light client | **done for Altair fixtures only**: no mainnet config, fork schedule or live beacon API (0066); Electra moves its indices. **The critical path** |
| a chain to test against | **built**: wacuum `--dev`, serving `eth_getProof` on its experiment branch |
| registry and revocation contracts (step 5) | **built for the experiment**: a contract of our own on the devnet (questions 1–3 still open for a real chain) |
| fetching from the network | **done**: `packages/fetch` |
| the loader (step 6) | **`wactrust run`**: a module spawned from checked bytes holding no authority; a page written out to open from `file://`. No loader page or extension |
