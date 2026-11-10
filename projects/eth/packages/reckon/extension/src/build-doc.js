// The document an admitted app is shown as (docs/browser-extension.md, R5): one page of the admitted tree, with
// everything it names from the tree inlined as `data:` URLs, and a shim that answers `fetch`, XHR and links within the
// tree by asking the extension page. The sandbox loader writes it in; its CSP lets nothing reach the network, so a
// reference this does not inline (outside the tree, or computed at run time and not asked through the shim) fails.
//
// The tree is only read here: `tree.read(path)` gives the verified bytes of a file, or null. Paths are relative to the
// tree's root, with no leading slash.

const ORIGIN = 'https://tree.invalid';

const TYPES = {
  html: 'text/html', htm: 'text/html', js: 'text/javascript', mjs: 'text/javascript', css: 'text/css',
  json: 'application/json', svg: 'image/svg+xml', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg',
  gif: 'image/gif', webp: 'image/webp', avif: 'image/avif', ico: 'image/x-icon', woff: 'font/woff', woff2: 'font/woff2',
  ttf: 'font/ttf', otf: 'font/otf', txt: 'text/plain', xml: 'application/xml', wasm: 'application/wasm',
  mp4: 'video/mp4', webm: 'video/webm', mp3: 'audio/mpeg', ogg: 'audio/ogg', pdf: 'application/pdf',
};

export function typeOf(path) {
  const m = /\.([a-z0-9]+)$/i.exec(path);
  return (m && TYPES[m[1].toLowerCase()]) || 'application/octet-stream';
}

/** `ref` as a path in the tree, seen from the file at `from`; null if it leaves the tree or is not a plain reference. */
export function inTree(ref, from) {
  if (!ref || /^(data|blob|javascript|mailto|about):/i.test(ref) || ref.startsWith('#')) return null;
  let u;
  try { u = new URL(ref, `${ORIGIN}/${from}`); } catch { return null; }
  if (u.origin !== ORIGIN) return null;
  let path = decodeURIComponent(u.pathname.slice(1));
  if (path === '' || path.endsWith('/')) path += 'index.html';
  return path;
}

function base64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

const utf8 = new TextDecoder();
const dataUrl = (type, bytes) => `data:${type};base64,${base64(bytes)}`;

/** A CSS text with every `url(...)` and `@import` it makes into the tree inlined, recursively. */
export function inlineCss(text, from, tree, report, depth = 0) {
  const one = (ref) => {
    const path = inTree(ref, from);
    if (path === null) { if (!/^(data:|#)/.test(ref)) report.outside.push(ref); return null; }
    const bytes = tree.read(path);
    if (bytes === null) { report.missing.push(path); return null; }
    if (typeOf(path) === 'text/css' && depth < 8) {
      return dataUrl('text/css', new TextEncoder().encode(inlineCss(utf8.decode(bytes), path, tree, report, depth + 1)));
    }
    return dataUrl(typeOf(path), bytes);
  };
  return text
    .replace(/@import\s+(?:url\()?\s*(['"])([^'"]+)\1\s*\)?/g, (all, q, ref) => { const d = one(ref); return d ? `@import url("${d}")` : all; })
    .replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (all, q, ref) => { const d = one(ref.trim()); return d ? `url("${d}")` : all; });
}

// ---------------------------------------------------------------- ES modules
//
// A module from a `data:` URL has no base, so its relative imports cannot resolve. So every module in the tree is
// rewritten: each specifier that names the tree (`./`, `../`, `/`, or a tree URL) becomes the absolute tree URL
// (https://tree.invalid/PATH), and `import.meta.url` its own tree URL, so `new URL('./x.js', import.meta.url)` names
// the tree too. Then an import map maps every module's tree URL to its rewritten `data:` URL. That serves static
// imports, `import()` with a literal or a computed tree URL, and cycles, since modules name each other by URL.
//
// Dedicated workers do not read the page's import map, so a module worker gets its graph inlined instead: each
// specifier replaced by the `data:` URL of the module it names, itself inlined the same way. A cycle in a worker's
// graph cannot be inlined and is reported. `new Worker(treeUrl)` is mapped by the shim, and a worker from anywhere
// else is refused.

const MODULE = /\.m?js$/i;
const SPECIFIERS = /(\b(?:import|export)\b[^;'"`]*?\bfrom\s*|\bimport\s*\(\s*|\bimport\s+)(['"])([^'"\n]+)\2/g;

/** `src`, a module at `path`, with every specifier that names the tree replaced by `to(path)`, and import.meta.url
 *  by its tree URL. */
function rewriteModule(src, path, to, report) {
  return src
    .replace(SPECIFIERS, (all, head, q, spec) => {
      if (!/^(\.{0,2}\/|https:\/\/tree\.invalid\/)/.test(spec)) {
        if (/^[a-z][a-z0-9+.-]*:/i.test(spec)) { if (!/^(data|blob):/i.test(spec)) report.outside.push(spec); }
        else report.bare.push(spec);
        return all;
      }
      const target = inTree(spec, path);
      if (target === null) return all;
      const t = to(target);
      return t === null ? all : `${head}${q}${t}${q}`;
    })
    .replace(/\bimport\.meta\.url\b/g, JSON.stringify(`${ORIGIN}/${path}`));
}

/** The import map for the page: every module in the tree, at its tree URL, as a rewritten `data:` URL. */
function importMap(tree, report) {
  const imports = {};
  for (const p of tree.paths || []) {
    if (!MODULE.test(p)) continue;
    const src = utf8.decode(tree.read(p));
    imports[`${ORIGIN}/${p}`] = dataUrl('text/javascript', new TextEncoder().encode(
      rewriteModule(src, p, (t) => tree.read(t) === null ? (report.missing.push(t), null) : `${ORIGIN}/${t}`, report)));
  }
  return imports;
}

/** A module worker's script: its graph inlined as `data:` URLs (dedicated workers ignore import maps). */
function workerModule(tree, path, report, memo = new Map(), stack = []) {
  if (memo.has(path)) return memo.get(path);
  if (stack.includes(path)) { report.cycles.push([...stack, path].join(' → ')); return null; }
  const bytes = tree.read(path);
  if (bytes === null) { report.missing.push(path); return null; }
  const src = rewriteModule(utf8.decode(bytes), path, (t) => workerModule(tree, t, report, memo, [...stack, path]), report);
  const url = dataUrl('text/javascript', new TextEncoder().encode(src));
  memo.set(path, url);
  return url;
}

/** The shim, run first in the page: fetch, XHR and links within the tree go to the extension page. */
function shim(pagePath, workers) {
  return `<script>(() => {
const PAGE = ${JSON.stringify(pagePath)}, ORIGIN = ${JSON.stringify(ORIGIN)};
const inTree = (ref) => { try { const u = new URL(String(ref), ORIGIN + '/' + PAGE); return u.origin === ORIGIN ? decodeURIComponent(u.pathname.slice(1)) : null; } catch { return null; } };
const waiting = new Map(); let n = 0;
addEventListener('message', (e) => { if (e.source !== parent || !e.data || !waiting.has(e.data.id)) return; const w = waiting.get(e.data.id); waiting.delete(e.data.id); w(e.data); });
const ask = (path) => new Promise((done) => { const id = ++n; waiting.set(id, done); parent.postMessage({ ask: path, id }, '*'); });
window.fetch = async (input, init) => {
  const path = inTree(input instanceof Request ? input.url : input);
  if (path === null) throw new TypeError('reckon: only the admitted tree can be fetched');
  const a = await ask(path);
  if (a.status !== 200) return new Response('not in the admitted tree', { status: 404, statusText: 'Not Found' });
  return new Response(a.body, { status: 200, headers: { 'content-type': a.type } });
};
window.XMLHttpRequest = class {
  constructor() { this.readyState = 0; this.status = 0; this.responseType = ''; this.response = null; this.responseText = ''; this.listeners = {}; }
  open(method, url) { this.url = url; this.readyState = 1; }
  setRequestHeader() {} overrideMimeType() {} abort() {} getAllResponseHeaders() { return ''; } getResponseHeader() { return null; }
  addEventListener(k, f) { (this.listeners[k] = this.listeners[k] || []).push(f); }
  fire(k) { if (this['on' + k]) this['on' + k](); for (const f of this.listeners[k] || []) f(); }
  send() {
    const path = inTree(this.url);
    if (path === null) { setTimeout(() => this.fire('error')); return; }
    ask(path).then((a) => {
      this.status = a.status === 200 ? 200 : 404; this.readyState = 4;
      const bytes = new Uint8Array(a.body || new ArrayBuffer(0));
      this.responseText = new TextDecoder().decode(bytes);
      this.response = this.responseType === 'arraybuffer' ? bytes.buffer : this.responseType === 'json' ? JSON.parse(this.responseText || 'null') : this.responseText;
      this.fire('readystatechange'); this.fire('load'); this.fire('loadend');
    });
  }
};
document.addEventListener('click', (e) => {
  const a = e.target.closest && e.target.closest('a[href]');
  if (!a || e.defaultPrevented) return;
  const href = a.getAttribute('href');
  if (href.startsWith('#')) return;
  e.preventDefault();
  const path = inTree(href);
  if (path !== null) parent.postMessage({ navigate: path }, '*');
}, true);
document.addEventListener('submit', (e) => e.preventDefault(), true);
const WORKERS = ${JSON.stringify(workers)};
const RealWorker = window.Worker;
window.Worker = function (url, options) {
  const href = url instanceof URL ? url.href : String(url);
  // A worker made from the page's own bytes (blob:, data:) holds nothing the page did not: allowed.
  if (/^(blob|data):/.test(href)) return new RealWorker(url, options);
  const path = inTree(href);
  if (path !== null && WORKERS[path]) return new RealWorker(WORKERS[path], options);
  throw new TypeError('reckon: a worker can only be a module of the admitted tree' + (path === null ? '' : ': ' + path));
};
})();</script>`;
}

const ATTRS = [
  ['script[src]', 'src'], ['img[src]', 'src'], ['source[src]', 'src'], ['video[src]', 'src'], ['audio[src]', 'src'],
  ['track[src]', 'src'], ['input[type=image][src]', 'src'], ['video[poster]', 'poster'], ['embed[src]', 'src'],
  ['link[rel~=icon][href]', 'href'], ['link[rel=preload][href]', 'href'], ['link[rel=manifest][href]', 'href'],
];

/**
 * The document for the page at `pagePath`: `{ html, report }`, where `report` lists what it named and could not
 * inline: `missing` (in the tree's terms, but not in the tree), `outside` (outside the tree), `modules` (module scripts
 * that import relative paths, which a `data:` URL cannot resolve).
 */
export function buildDocument(tree, pagePath) {
  const report = { missing: [], outside: [], modules: [], bare: [], cycles: [] };
  const bytes = tree.read(pagePath);
  if (bytes === null) throw new Error(`${pagePath} is not in the admitted tree`);
  const doc = new DOMParser().parseFromString(utf8.decode(bytes), 'text/html');
  const inline = (el, attr) => {
    const ref = el.getAttribute(attr);
    const path = inTree(ref, pagePath);
    if (path === null) { if (!/^(data:|#)/.test(ref)) report.outside.push(ref); return; }
    const b = tree.read(path);
    if (b === null) { report.missing.push(path); return; }
    if (el.localName === 'script' && el.type === 'module') {
      // A module's own imports go through the import map, so the script itself is the rewritten module.
      el.setAttribute(attr, dataUrl('text/javascript', new TextEncoder().encode(
        rewriteModule(utf8.decode(b), path, (t) => `${ORIGIN}/${t}`, report))));
      return;
    }
    el.setAttribute(attr, dataUrl(typeOf(path), b));
  };
  for (const [sel, attr] of ATTRS) for (const el of doc.querySelectorAll(sel)) inline(el, attr);
  for (const el of doc.querySelectorAll('link[rel~=stylesheet][href]')) {
    const ref = el.getAttribute('href');
    const path = inTree(ref, pagePath);
    if (path === null) { report.outside.push(ref); continue; }
    const b = tree.read(path);
    if (b === null) { report.missing.push(path); continue; }
    el.setAttribute('href', dataUrl('text/css', new TextEncoder().encode(inlineCss(utf8.decode(b), path, tree, report))));
  }
  for (const el of doc.querySelectorAll('img[srcset], source[srcset]')) {
    el.setAttribute('srcset', el.getAttribute('srcset').split(',').map((part) => {
      const [ref, ...size] = part.trim().split(/\s+/);
      const path = inTree(ref, pagePath);
      const b = path === null ? null : tree.read(path);
      return [b === null ? ref : dataUrl(typeOf(path), b), ...size].join(' ');
    }).join(', '));
  }
  for (const el of doc.querySelectorAll('style')) el.textContent = inlineCss(el.textContent, pagePath, tree, report);
  for (const el of doc.querySelectorAll('[style]')) el.setAttribute('style', inlineCss(el.getAttribute('style'), pagePath, tree, report));
  // Modules: inline module scripts rewritten as from the page; the app's own import map folded into the tree's.
  const imports = importMap(tree, report);
  for (const el of doc.querySelectorAll('script[type=importmap]')) {
    try {
      const theirs = JSON.parse(el.textContent).imports || {};
      for (const [k, v] of Object.entries(theirs)) { const t = inTree(v, pagePath); imports[k] = t === null ? v : (imports[`${ORIGIN}/${t}`] || v); }
    } catch { report.outside.push('an import map that is not JSON'); }
    el.remove();
  }
  for (const el of doc.querySelectorAll('script[type=module]:not([src])')) {
    el.textContent = rewriteModule(el.textContent, pagePath, (t) => `${ORIGIN}/${t}`, report);
  }
  // Workers: every module the tree's scripts might start as one, inlined, if any script mentions a Worker.
  const workers = {};
  if ((tree.paths || []).some((p) => MODULE.test(p) && /\bWorker\s*\(/.test(utf8.decode(tree.read(p))))) {
    for (const p of tree.paths) if (MODULE.test(p)) { const u = workerModule(tree, p, { missing: [], outside: [], modules: [], bare: [], cycles: [] }); if (u) workers[p] = u; }
  }
  // What is left to say: each once, and a bare specifier only if no import map names it.
  report.bare = [...new Set(report.bare)].filter((b) => !(b in imports));
  report.outside = [...new Set(report.outside)];
  report.missing = [...new Set(report.missing)];
  for (const el of doc.querySelectorAll('base, meta[http-equiv]')) el.remove();
  const head = doc.head || doc.documentElement;
  head.insertAdjacentHTML('afterbegin', shim(pagePath, workers) +
    (Object.keys(imports).length ? `<script type="importmap">${JSON.stringify({ imports }).replace(/</g, '\\u003c')}</script>` : ''));
  return { html: '<!doctype html>\n' + doc.documentElement.outerHTML, report };
}
