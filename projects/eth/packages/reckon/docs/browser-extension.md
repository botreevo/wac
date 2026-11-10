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
sandbox loader (packaged, opaque origin, CSP: no network) ◄── the page posts it the app's document, built from
        │                                                     verified blocks with subresources inlined
        └── fetch(path) ──postMessage──► the page answers from the admitted tree only
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
- **Serving the app: measured, see "The spike" below.** A service worker can't serve an opaque-origin frame. Instead,
  a packaged MV3 sandbox page (`sandbox.pages`: a unique origin, no extension API, its own CSP with `connect-src
  'none'`) is handed the app's document, built from verified blocks. The document's subresources are inlined as
  `data:` URLs, and `fetch` is answered by the extension page over `postMessage` from the admitted tree only.

## What changes, and where

| | Change | Where |
| --- | --- | --- |
| W1 | **An HTTP capability in the browser host** (landed in wac 78c748c1: `wac.http`, the page's fetch). A host-provided request/response, e.g. `wac.http ^1`: method, URL, headers, body in; status, headers, body out. Answered in `platform/host/browser.ts` (and an extension host) by `fetch`. Then wac's `fetch` package and `http` client use it when the host offers it, and sockets otherwise, so programs don't change. Without W1 nothing in the browser can reach a beacon node, an RPC or a mirror. **Blocks milestone 1** | **[wac]** |
| W2 | **`--target browser` for a project with dependencies, and for an extension.** (W2a, the packages, landed in wac 78c748c1; W2b, `--layout files` for MV3, is next.) Found by trying: `build.ts` reads the import graph itself (`harness/wacFiles.ts`), resolving relative, `@/`, core and std imports, and **not the packages a project's `wac.lock` pins**. Every program in wac-eth imports `"wac"`, so `cmd/web.wac` fails with 54 imports unresolved. That **blocks milestone 1 as much as W1**. A `--target browser` in `wac build` itself, which already resolves packages, would fix this and W3 at once. Also: today it emits one self-contained HTML page. An extension needs the worker and the wasm as files, not inline strings, because MV3's CSP forbids inline script, plus a module launcher and a way to pass arguments other than the query string | **[wac]** packages/platform/build.ts, or `wac build` |
| W3 | **Building in this container.** `app:build` is a deno task, and deno isn't installed here. Measured: deno installs from npm (`npm install deno`), and with it a program with no package imports (`corpus/probe.wac`) builds and runs in headless Chromium, its clock, random bytes and arguments as expected. `build.ts` must be run from a wac checkout at a path with no `%`: from the package cache's path, deno's file URLs mangle `%3A` | environment (solved locally) |
| R1 | **Admission as a library.** Move `claim admit`'s flow (anchor, name, chain, claims, decision) out of `cmd/claim.wac` into `src/admission.wac`: `admitSubject(sys, Request) → Admitted{ ok, why[], cid, log[] }`. Then `claim` and the browser entry are thin over it | **[reckon]** |
| R2 | **A browser entry,** `cmd/web.wac`: `main(Sys)` taking the subject, role and settings, running R1, then fetching the tree, so the worker hands verified blocks to the service worker | **[reckon]** |
| R3 | **CORS on the replays.** `tools/replay.mjs` and `tools/beacon-replay.mjs` answer `OPTIONS` and send `Access-Control-Allow-Origin: *` and `Access-Control-Expose-Headers: Eth-Consensus-Version`, so a page served from another port can use them | **[reckon]** |
| R4 | **Light-client state kept between runs** (done: `--state`, docs/admit.md). `src/checkpoint.wac` writes the store it ends with (finalized header, committees) and starts from it next time. A check is then a few requests, not a bootstrap | **[reckon]** (lightclient's store type is serialized here, not changed) |
| R5 | **The extension.** Manifest, UI page, settings, the sandbox loader, and the document builder: an admitted tree's HTML with its scripts, styles, images and fonts inlined as `data:` URLs (CSS `url()` too), a `fetch`/XHR shim answered from the tree, and links within the tree re-rendered in place | **[reckon]**, `packages/reckon/extension/` |

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
   `admit-by-name.sh` checks on the command line. **Done (2026-11-10, wac 78c748c1, which has W1 and W2a).**
   `tools/browser-admit.sh` passes 10 of 10:
   - `cmd/web.wac` (R2, over R1) admits ens:vitalik.eth on the command line;
   - it is built with `--target browser`, 667 KB, and in headless Chromium admits ens:vitalik.eth on recorded mainnet
     data, all of its HTTP the browser's own fetch, against the replays (R3, with CORS);
   - in the browser it refuses a wrong checkpoint, a changed bootstrap, update and finality update, a header that is
     not the anchor's, and a changed storage proof, each for its own reason.
   The whole admission takes about two seconds in the page.
2. **The extension shell.** MV3 manifest, a UI page, the worker running milestone 1's module from packaged files
   (W2), and settings. It admits a name and shows the account. No app is served yet.
3. **Serving the admitted app,** through the sandbox loader (R5). Test it with the capstone's app, a static site
   (vitalik.eth's, from the gateway), and a hostile app that tries every way out (the spike's `main.js` is the
   start of one).
4. **State and freshness.** Light-client state persisted (R4), revocations proved on chain each time an app is
   opened, and a visible "as of block N" on the page.
5. **Hardening.** Size and start-up time, the extension built as a derivation, and an admission of the extension by
   its own policy.
6. **Published.** A zip (and a `.crx` if signing is settled) with install instructions as a download on the reckon
   pages site reckon1 is building, and live in-browser demos there if feasible. The download is named by its CID,
   with the claims that admit it.

## Risks and open questions

- **Apps that compute URLs.** The loader inlines what the HTML names, and answers `fetch` and XHR from the tree.
  ES modules that import relative paths, workers, dynamic `import()` and navigation by `location` need more
  rewriting (an import map of `data:` URLs, worker sources by message). A static site works as it is; an app may
  not, and the page should say which it found.
- **Size.** `claim.wasm` is about 540 KB today. With the light client and BLS it is still fine for an extension;
  start-up is measured in milestone 1.
- **CPU.** The light client's BLS checks run in V8 as they do on the Node host. Milestone 1 will time them.
- **Gateway availability.** trustless-gateway.link answered HTTP 522, then 526, all through 2026-11-10 (capstone.md). The
  extension takes a list of gateways and mirrors, in order, as `--mirror` does.

## The spike (2026-11-10)

`extension/spike/` is a minimal MV3 extension, run under Playwright's Chromium with `node run.cjs`, while
`node hits.mjs` listens on 127.0.0.1:8899 to show whether anything an app tries reaches the network. The app tries:
- its own script, style and image;
- `fetch` in its tree, from another root, and from the internet;
- XHR, a remote image, `sendBeacon`, a WebSocket, a frame and a popup.

| How the app is shown | Origin and `chrome.*` | Subresources | Network |
| --- | --- | --- | --- |
| a frame with `sandbox="allow-scripts"`, its page from the extension's service worker | the frame never loads: its navigation does not reach the worker | none | none |
| `sandbox="allow-scripts allow-same-origin"` | **the extension's own origin, with `tabs`, `management`, `runtime`…**: unacceptable | all through the worker, another root's too | the extension's CSP blocks it |
| no attribute, the worker's response carrying `Content-Security-Policy: sandbox allow-scripts` | opaque | **not through the worker**: they go to the extension's packaged files and fail (`ERR_FILE_NOT_FOUND`) | none |
| the same, everything inlined | opaque | **blocked**: the extension pages' CSP applies, and MV3 allows no inline or `data:` script there | none |
| **a packaged `sandbox.pages` loader, handed the document by `postMessage`** | **`null`; no extension API** (only `loadTimes` and `csi`, which web pages have) | inlined `data:` URLs: script, CSS and image all load; `fetch` in the tree answered by the parent; another root and the internet refused | **nothing reached the listener**: `connect-src 'none'`, `img-src data:` and the sandbox block XHR, the remote image, the beacon (accepted, never sent), the WebSocket, the frame and the popup |

So the main risk is settled. A service worker can't serve an opaque-origin frame. A packaged sandbox page, with the
app inlined into it from verified bytes and a CSP that allows no network, can show it, with no extension API and
nothing outside its tree.
