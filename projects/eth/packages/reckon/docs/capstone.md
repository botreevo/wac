# The capstone: the motivating case, end to end

`tools/capstone.sh` (task `reckon:capstone`) is the whole design in one run. It goes from source, through the
compiler that builds it, to an app, a name, and a client that runs the app having trusted nothing but its policy and
an anchor. Every step is one this repository already does on its own, and the script puts them in order.

    WASMTIME_WAC=/path/to/native/wac sh packages/reckon/tools/capstone.sh WORKDIR     # about 30 minutes
    QUICK=1 …                                                                       # a few minutes: no self-build
    LADDER=… (not QUICK)                                                            # the ladder as a second origin

## What it does

1. **Build.** A seed compiler, wac's own at the commit wac-eth pins, built natively. Inside the machine
   (`wasm-gc/wac-host/2`: sealed, canonical NaNs), on V8 and on wasmtime:
   - the seed builds the compiler from its own source (QUICK skips this, and the seed is the compiler);
   - that compiler builds the app from its source;
   - the app's run is derived too.

   Each step is a recipe whose output is a CID, signed by a runner on each engine, and each must agree across the
   engines.
2. **Publish.** A reviewer endorses the sources (the app's and, unless QUICK, the compiler's). The builder's store,
   which holds every object and signed claim, becomes a mirror: `claim publish`, served by a plain web server.
3. **Name.** A devnet with ENS's storage layout (`contracts/DevENS.sol`) and the registry (`contracts/Registry.sol`).
   `capstone.reckon.eth` points at the app's CID.
4. **A fresh client.** An empty store, the policy, an anchor, and one command:

       claim admit ens:capstone.reckon.eth app --policy … --anchor … --rpc … --registry … --mirror http://…

   The name is read by proof at the anchored block. The claims come from the mirror, every signature verified, and
   on-chain revocations are proved there too. The app is admitted through the derivation graph: its bytes are at
   `out/capstone.wasm` in a build that two runners witnessed. That build's compiler was itself derived by two runners
   from reviewed source by the seed, and its source was reviewed. Then the app's bytes are fetched from the mirror,
   every block checked against its CID, and run.

   4b does the same on recorded mainnet with `--checkpoint`. The light client proves the anchor from a beacon
   checkpoint, and vitalik.eth is resolved and admitted under a reviewer's endorsement.
5. **What it refuses:**
   - a tampered build output: other bytes for the app, refused at the fetch; a changed build tree, refused at
     admission;
   - a missing endorsement: a mirror without the reviewer's claims;
   - a lying mirror: a forged statement, left out and named, so the build lacks its second witness;
   - a revoked runner: wasmtime's runner withdraws its derivation on chain. An anchor after that is refused, and
     the anchor before it still admits, since it reads that block's state.

## What it showed (2026-11-10)

24 of 24, and 22 of 22 with QUICK. Every derivation agreed across V8 and wasmtime.

With LADDER, at wac 64e87365, the run passes 27 of 27:
- the ladder built a compiler from its rungs (2,614,977 bytes) with no compiler binary;
- inside the machine, on both engines, that compiler built the same compiler tree as the seed;
- the compiler was admitted through `agree`, both origins holding;
- with the ladder's endorsement revoked on a copy of the store, the seed alone was refused ("origin 2 of 2 does not
  hold"). The app's CID
(`bafkreihqj7pxd3hu…`) is the same whether the seed or the compiler it built does the building. That is the
compiler's fixed point (selfbuild.sh) seen from the outside: the derived compiler builds exactly what the seed builds.

## What is still trusted, or stubbed

Said plainly, because the point is to know exactly what an answer rests on.

- **The seed compiler is a trust root, but no longer the only origin.** The compiler that builds the app is derived
  (unless QUICK). The compiler that built it, wac's own at the pinned commit built natively, is named in the policy's
  `roots`.
  - With `LADDER` (step 1a+), the compiler has a second, unrelated origin: wac's bootstrap ladder builds a compiler
    from its hand-written rungs, and that one builds the same compiler tree inside the machine on both engines.
  - The policy's `selfbuild` role is then `agree: [via the seed, via the ladder]`, which is diverse double-compiling.
    The compiler is admitted only when both build it, so a backdoor in the seed would have to be in the ladder's
    output too. With the ladder's origin withdrawn, the seed alone is refused.
  - The ladder's output is endorsed by the key that ran the ladder (`bootstrap`) and is not a root. That is milestone
    1's unsigned step, stated as what it is.
  - Making the ladder's own steps derivations and taking the seed out of `roots` altogether is decision **D**'s
    remaining work (docs/bootstrap-derivations.md).
- **On the devnet, the anchor is a block hash taken from the node.** A devnet has no beacon chain, so nothing proves
  its headers. The run takes the node's latest block hash as the anchor, and every read is then fixed to it, so the
  node cannot answer from another block. But that the block is the "right" chain rests on the node. On mainnet the
  anchor comes from the light client and a checkpoint (4b), and nothing else is trusted.
- **The devnet's contracts are fixtures.** DevENS has ENS's storage layout and none of its hierarchy, and the
  registry is deployed fresh. Their code hashes are checked, against what this run deployed.
- **Mainnet content comes from a public gateway, when it answers.** Andrew decided **G**: a public trustless gateway
  may serve content, trusted only to be there. A gateway is a `--mirror https://HOST` like any other: `Store.gateway`
  asks for each block raw (`/ipfs/CID?format=raw`) through wac's `fetch`, with TLS checked against the trust store,
  and every block is re-hashed against its CID. 4b runs `claim run ens:vitalik.eth site … --mirror
  https://trustless-gateway.link --out`, which admits the CID, fetches the site and writes it out from checked
  blocks. **Not yet seen to pass:** on 2026-11-10 the gateway answered every request from Cloudflare with HTTP 522 (its
  origin timed out), and later 526 (its origin's certificate is invalid). So 4b reports a skip and counts nothing,
  and the QUICK run is 22 of 22 with that skip. The same path passes against a local HTTPS mirror
  (`tools/run.sh`, `packages/ipfs/tools/http-mirror.sh`). Nothing is recorded yet: the content is fetched live, and
  whether it is small enough to record is unknown until the gateway answers.
- **The mainnet half is recorded.** Its beacon and execution data come from `packages/lightclient/test/mainnet`,
  replayed by local servers. The live path (`--beacon-url` against a public node) is shown in docs/admit.md.
- **Keys and the policy are the user's.** The three signers and the policy file are what the client trusts by
  choice, which is the design.
- **What the machine does not yet bound.** `docs/runner.md` lists the floor (stack and heap) and what remains. Builds
  with dependencies are now wholly inside it and signed (`--wac-home`, since wac fade22039).
