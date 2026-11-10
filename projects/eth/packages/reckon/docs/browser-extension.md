# The browser extension: a plan

Andrew chose K3's recommendation (docs/decisions/K3-browser.md): a Manifest V3 extension in which nothing unverified
runs and no first load is trusted. This plan is for review before anything past milestone 1 is built. Each part is
marked **[reckon]** if it is ours, or **[wac]** if it needs a change in wac or wac-web, so those can be routed.

## What the extension does

The user types `ens:NAME` or `name:NAME@0xPUB` (or a CID) into the extension's page. Then:

1. **Anchor.** The light client advances from its stored state, or from the checkpoint the extension ships with, to
   a finalized execution block. That takes a few requests to a beacon node.
2. **Name.** The name is read by proof at that block.
3. **Claims.** The claim index is read from the user's mirrors, every signature checked, and revocations and
   rejections are proved from the registry.
4. **Decision.** The policy decides, as `claim admit` does today. The page shows the account ("why") either way.
5. **Bytes.** The admitted tree's blocks come from the user's mirrors and gateways, each checked against its CID,
   and are kept in the extension's storage.
6. **Run.** The app is served from those blocks in a sandboxed frame. A request for a path under the app's root
   resolves inside the admitted tree, and anything outside it is refused.

Steps 1 to 5 are `claim run --out` (docs/admit.md#claim-run), compiled to WebAssembly. Step 6 is new.

## Architecture

```
extension page (UI) ──► worker: admission (wac → wasm, main(Sys)) ──► fetch (host_permissions: beacon, RPC, mirrors)
        │                       │ store: OPFS (blocks, claim index, light-client state)
        ▼                       ▼
sandboxed frame  ◄── extension service worker: answers /app/<root-cid>/<path> from verified blocks only
```

- **Admission runs as a `main(Sys)` program in a worker,** built with wac's `--target browser` (packages/platform).
  That target already runs a program in a worker that may block, through `SharedArrayBuffer` and `Atomics.wait`. This
  matters because reckon's store, resolver, `fetch` and `ethrpc` are synchronous (`.wait()`), which wac-web's
  `main(Page)` pages forbid. An extension page can set `cross_origin_embedder_policy` and
  `cross_origin_opener_policy` in its manifest, which `SharedArrayBuffer` needs. The CSP needs `'wasm-unsafe-eval'`.
- **Network is HTTP, by the browser's `fetch`.** A page has no TCP: the platform's browser host refuses `CONNECT`,
  on purpose (platform README, "A page has no TCP"). reckon reaches the network in three places:
  - `ethrpc` over wac's `http.get` on raw sockets;
  - wac's `fetch` package (TLS in wac) for `--beacon-url` and `https://` mirrors;
  - `Store.http`, also over raw sockets.

  All three must reach an HTTP capability the host provides. In an extension, `host_permissions` let the worker
  fetch the beacon node, RPC and mirrors without CORS. A plain page (milestone 1) needs the servers to send CORS
  headers.
- **Storage** is OPFS, which the platform's browser host already maps `Files` onto. The store directory, the
  claim index and the light client's state live there, per extension.
- **Serving the app.** The extension's service worker answers requests under `chrome-extension://ID/app/<cid>/`
  from blocks already in OPFS, by path inside the admitted tree. The frame showing the app must hold no extension
  API, and must not be able to fetch outside its tree. This is the least certain part (see the risks below).

## What changes, and where

| | Change | Where |
| --- | --- | --- |
| W1 | **An HTTP capability in the browser host.** A host-provided request/response, e.g. `wac.http ^1`: method, URL, headers, body in; status, headers, body out. Answered in `platform/host/browser.ts` (and an extension host) by `fetch`. Then wac's `fetch` package and `http` client use it when the host offers it, and sockets otherwise, so programs don't change. Without W1 nothing in the browser can reach a beacon node, an RPC or a mirror. **Blocks milestone 1** | **[wac]** |
| W2 | **`--target browser` for an extension.** Today it emits one self-contained HTML page. An extension needs the worker and the wasm as files, not inline strings, because MV3's CSP forbids inline script, plus a launcher that is a module script and a way to pass arguments other than the query string | **[wac]** packages/platform/build.ts |
| W3 | **Building in this container.** `app:build` is a deno task, and deno isn't installed here, so 20 of wac-eth's oracle tests also fail. Install deno, or give `wac` itself a `--target browser` | **[wac]** or environment |
| R1 | **Admission as a library.** Move `claim admit`'s flow (anchor, name, chain, claims, decision) out of `cmd/claim.wac` into `src/admission.wac`: `admitSubject(sys, Request) → Admitted{ ok, why[], cid, log[] }`. Then `claim` and the browser entry are thin over it | **[reckon]** |
| R2 | **A browser entry,** `cmd/web.wac`: `main(Sys)` taking the subject, role and settings, running R1, then fetching the tree, so the worker hands verified blocks to the service worker | **[reckon]** |
| R3 | **CORS on the replays.** `tools/replay.mjs` and `tools/beacon-replay.mjs` answer `OPTIONS` and send `Access-Control-Allow-Origin: *` and `Access-Control-Expose-Headers: Eth-Consensus-Version`, so a page served from another port can use them | **[reckon]** |
| R4 | **Light-client state kept between runs.** `src/checkpoint.wac` writes the store it ends with (finalized header, committees) and starts from it next time. A check is then a few requests, not a bootstrap | **[reckon]** (lightclient's store type is serialized here, not changed) |
| R5 | **The extension.** Manifest, UI page, settings, service worker serving `/app/<cid>/…`, and the sandboxed frame | **[reckon]**, new `packages/reckon/extension/` |

## Trust roots and settings

All of these are in the extension's settings, kept in extension storage, and shown on the page beside every
decision:
- **Checkpoint:** a beacon block root shipped with the extension. The user can override it, and it is replaced by
  the light client's own state as it advances (R4).
- **Policy:** the JSON5 file `claim admit` reads, pasted or picked.
- **Beacon node(s) and execution RPC(s):** trusted for availability only.
- **Mirrors and gateways:** trusted for availability only. The default gateway is https://trustless-gateway.link
  (decision G).
- **Registry address and code hash,** for revocations, rejections and `name:` subjects (K1).

Nothing else is trusted. In particular, the extension never loads code from the network for itself. Its own code is
what the user installed, and its build can itself be a derivation, so it can be admitted by the same policy.

## Milestones

1. **Admission in a real browser** (the coordinator's milestone 1). Headless Chromium (Playwright, preinstalled)
   loads a page built with `--target browser` from the browser entry (R2, over R1). Against `replay.mjs` and
   `beacon-replay.mjs` (R3) on recorded mainnet data, it admits `ens:vitalik.eth` under a reviewer's endorsement,
   with the claims from a mirror served over HTTP. A tampered beacon update and a tampered proof are refused, as
   `admit-by-name.sh` checks on the command line. This needs W1 (and W3 to build here). Without W1, I can do R1,
   R2 and R3, and a Playwright harness that shows the run reaching its first network request and being refused with
   "network access".
2. **The extension shell.** MV3 manifest, a UI page, the worker running milestone 1's module from packaged files
   (W2), and settings. It admits a name and shows the account. No app is served yet.
3. **Serving the admitted app.** The service worker serves `/app/<cid>/…` from verified blocks, in the sandboxed
   frame. Test it with the capstone's app and with a static site (vitalik.eth's, from the gateway).
4. **State and freshness.** Light-client state persisted (R4), revocations proved on chain each time an app is
   opened, and a visible "as of block N" on the page.
5. **Hardening.** Size and start-up time, the extension built as a derivation, and an admission of the extension by
   its own policy.

## Risks and open questions

- **The sandboxed frame and the service worker.** MV3 "sandbox" pages get a unique origin and no extension APIs,
  but they are packaged files, not served by the service worker. A frame with the `sandbox` attribute has an opaque
  origin, and whether its subresource requests reach the extension's service worker needs a spike. The fallback is
  a sandboxed frame whose document is built from verified bytes (`srcdoc`), with subresources served as `blob:`
  URLs, rewritten from the tree. That works for static sites with relative links and not for apps that compute URLs.
- **Size.** `claim.wasm` is about 540 KB today. With the light client and BLS it is still fine for an extension;
  start-up is measured in milestone 1.
- **CPU.** The light client's BLS checks run in V8 as they do on the Node host. Milestone 1 will time them.
- **Gateway availability.** trustless-gateway.link answered HTTP 522, then 526, all through 2026-11-10 (capstone.md). The
  extension takes a list of gateways and mirrors, in order, as `--mirror` does.
