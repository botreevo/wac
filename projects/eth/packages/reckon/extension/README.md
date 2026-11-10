# The reckon extension (MV3)

The plan is in [../docs/browser-extension.md](../docs/browser-extension.md). This is milestone 2's shell:

| | |
| --- | --- |
| `src/manifest.json` | MV3. The page is cross-origin isolated (COOP and COEP, so the admission worker can block on `SharedArrayBuffer`). `'wasm-unsafe-eval'` is allowed. `loader.html` is a sandbox page with its own CSP: no network at all |
| `src/page.html`, `page.js` | settings (checkpoint, beacon node, RPC, registry, mirrors, policy) in extension storage; a subject to open; admission's account; the app |
| `src/admission.js` | admission as the page sees it. **A stub that refuses** until wac can build `cmd/web.wac` for a page and give it HTTP (W1, W2 in the plan) |
| `src/tree.js` | admitted trees in OPFS, `trees/<cid>/`, as admission writes them out |
| `src/build-doc.js` | the document an admitted page is shown as: what it names from the tree (scripts, styles and their `@import`/`url()`, images, `srcset`, icons, media) inlined as `data:` URLs, and a shim answering `fetch`, XHR and links within the tree |
| `src/loader.html` | the sandbox page: a unique origin, no extension API, handed that document once |
| `spike/` | how apps came to be shown this way: the five ways measured |

Test it with `node test/shell.cjs`, under Playwright's Chromium. It passes 16 of 16:
- the extension loads, and its page is isolated;
- the stub refuses, and nothing is shown;
- a fixture app put in OPFS is shown through the loader: its styles (and one imported), image, `fetch` and XHR in the
  tree, a 404 for a path not in it, and a link to another page in the tree;
- its origin is `null`, it holds no extension API, and fetch, XHR, an image, a beacon and a WebSocket to a listening
  server all fail, and nothing reaches the server.

Loading it unpacked: `chrome://extensions`, Developer mode, "Load unpacked", choose `src/`.
