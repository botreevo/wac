# K3: loading web apps in a browser

**Decide:** where verification runs when the thing being admitted is a web app, what the browser-side trust roots
are, and how the light client fits.

## The problem

Today, admission ends at a verified file on disk: `obj cat`, or v1's `reckon run --out`, which writes checked bytes
to open from `file://`. A browser that loads `https://app.example` trusts that origin's server for every byte, which
is exactly what reckon removes. Verification has to happen before the browser executes anything, in code the user
already trusts.

## Where verification can run

| | Browser extension | Service worker under a loader page | Native helper | Verifying gateway |
| --- | --- | --- | --- | --- |
| Runs before the app's bytes execute | Yes. It can serve the app from verified bytes in its own pages, or redirect requests to them | Yes, for requests under its scope, after it is installed | Yes: it writes checked files, and the browser opens `file://` | Yes, but on the gateway |
| What the user must trust first | The extension's code, installed once from a store or built from source | **The loader page, on first load** (trust on first use), and then its service worker | The helper binary | **The gateway**, which defeats the purpose |
| Can run `lc` and proofs | Yes: wac compiles to WebAssembly, and the extension has network access | Yes, the same | Yes | n/a |
| Web-platform limits | MV3 restricts blocking request rewrites, so serve from extension pages, which works | Scope is per origin, and its first install is unverified | `file://` breaks many apps (no origin, so fetch, cookies and workers misbehave) | none |
| Effort | Highest | Medium | Lowest (v1 did it) | Low |

## Trust roots in the browser

The same as on the command line, held by the verifying code: a **beacon checkpoint** (refreshed as the light client
follows the chain, so it is set once and kept current), the **policy** (keys and roots), and the user's choice of
mirrors and RPC endpoints. The last are trusted for availability only. The checkpoint can ship with the extension
and be overridden by the user.

## How `lc` fits

`lc`, the proof readers and admission are wac, so they compile to WebAssembly and run in a browser. What they need
from the host is `fetch`. Beacon nodes serve the light-client REST API, and the public node used here exposes
`Eth-Consensus-Version` for cross-origin reads (`access-control-expose-headers`). Execution RPCs serve
`eth_getProof`. The light client's store can be kept in extension storage and advanced as it goes, so a check costs
a few requests, not a bootstrap.

## Recommendation

**A browser extension first, with the native helper as today's working path.** The extension is the only option
where nothing unverified runs and no first load is trusted. The service-worker loader is a fallback for people who
will not install anything. Its first-load trust is real, and it should say so on the page. Don't build the gateway.

## What changes in code

- **Common to the browser options:** a browser host for wac programs (a JS shim for `fetch`, storage and the clock;
  wac has Node and Deno hosts to start from), and `claim admit`'s core packaged as a library entry point, not a
  command: anchor, name, chain, claims, decision, then the verified bytes.
- **Extension:** a Manifest V3 extension with a page that takes a subject (`ens:NAME`), runs the library, and renders
  the admitted app from verified bytes in a sandboxed frame, mapping its relative URLs to blocks under the same
  root CID. Settings for the checkpoint, policy, mirrors and RPCs.
- **Loader page:** the same library in a service worker that answers the app's requests from verified blocks.
- **Native helper:** nothing new beyond a `claim run` command (see J) that writes the admitted tree out.
