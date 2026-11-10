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

/** The shim, run first in the page: fetch, XHR and links within the tree go to the extension page. */
function shim(pagePath) {
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
  const report = { missing: [], outside: [], modules: [] };
  const bytes = tree.read(pagePath);
  if (bytes === null) throw new Error(`${pagePath} is not in the admitted tree`);
  const doc = new DOMParser().parseFromString(utf8.decode(bytes), 'text/html');
  const inline = (el, attr) => {
    const ref = el.getAttribute(attr);
    const path = inTree(ref, pagePath);
    if (path === null) { if (!/^(data:|#)/.test(ref)) report.outside.push(ref); return; }
    const b = tree.read(path);
    if (b === null) { report.missing.push(path); return; }
    if (el.localName === 'script' && el.type === 'module' && /\bimport\b[^;]*['"]\.\.?\//.test(utf8.decode(b))) report.modules.push(path);
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
  for (const el of doc.querySelectorAll('base, meta[http-equiv]')) el.remove();
  const head = doc.head || doc.documentElement;
  head.insertAdjacentHTML('afterbegin', shim(pagePath));
  return { html: '<!doctype html>\n' + doc.documentElement.outerHTML, report };
}
