// The extension's service worker: answers /app/<root>/<path> itself, as the extension would from verified blocks.
// It counts what it saw, so the test can ask.
const seen = [];
const files = {
  'index.html': ['text/html', `<!doctype html><meta charset=utf-8><link rel=stylesheet href="style.css">
<img id=img src="pic.svg"><script src="main.js"></script>`],
  'main.js': ['text/javascript', `
const r = (k, v) => parent.postMessage({ k, v }, '*');
r('origin', String(self.origin));
r('chrome', typeof chrome === 'undefined' ? 'none' : Object.keys(chrome).join(','));
r('script', 'ran');
fetch('data.json').then(x => x.text()).then(t => r('fetch-relative', t), e => r('fetch-relative', 'error ' + e));
fetch(new URL('../other/secret.txt', location.href)).then(x => x.text()).then(t => r('fetch-other-root', t), e => r('fetch-other-root', 'error ' + e));
fetch('https://example.com/').then(x => r('fetch-internet', 'status ' + x.status), e => r('fetch-internet', 'error ' + e));
document.getElementById('img').onload = () => r('img', 'loaded');
document.getElementById('img').onerror = () => r('img', 'error');
setTimeout(() => r('css', getComputedStyle(document.body).backgroundColor), 300);
try { const x = new XMLHttpRequest(); x.open('GET', 'http://127.0.0.1:8899/xhr'); x.onload = () => r('xhr-network', 'loaded'); x.onerror = () => r('xhr-network', 'error'); x.send(); } catch (e) { r('xhr-network', 'threw ' + e.name); }
const im = new Image(); im.onload = () => r('img-network', 'loaded'); im.onerror = () => r('img-network', 'error'); im.src = 'http://127.0.0.1:8899/img';
try { r('beacon', String(navigator.sendBeacon('http://127.0.0.1:8899/beacon', 'x'))); } catch (e) { r('beacon', 'threw ' + e.name); }
try { const w = new WebSocket('ws://127.0.0.1:8899/ws'); w.onerror = () => r('websocket', 'error'); w.onopen = () => r('websocket', 'open'); } catch (e) { r('websocket', 'threw ' + e.name); }
try { const f = document.createElement('iframe'); f.src = 'http://127.0.0.1:8899/frame'; document.body.appendChild(f); } catch (e) {}
try { window.open('http://127.0.0.1:8899/popup'); } catch (e) {}

`],
  'style.css': ['text/css', 'body { background: rgb(1, 2, 3); }'],
  'pic.svg': ['image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'],
  'data.json': ['application/json', '{"from":"the service worker"}'],
};
const b64 = (t) => btoa(unescape(encodeURIComponent(t)));
const dataUrl = (name) => `data:${files[name][0]};base64,${b64(files[name][1])}`;
const shim = `<script>
const pending = new Map(); let n = 0;
window.addEventListener('message', (e) => { if (e.source !== parent) return; const p = pending.get(e.data.id); if (p) { pending.delete(e.data.id); p(e.data); } });
window.fetch = (u) => new Promise((ok, no) => { const id = ++n; pending.set(id, (m) => m.status === 200 ? ok(new Response(m.body, { status: 200 })) : no(new TypeError('not in the tree'))); parent.postMessage({ ask: String(u), id }, '*'); });
</script>`;
files['inline.html'] = ['text/html', '<!doctype html><meta charset=utf-8>' + shim + `<link rel=stylesheet href="${dataUrl('style.css')}"><img id=img src="${dataUrl('pic.svg')}"><script src="${dataUrl('main.js')}"></script>`];
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  seen.push({ path: u.pathname, mode: e.request.mode, dest: e.request.destination, client: e.clientId ? 'yes' : 'no', resulting: e.resultingClientId ? 'yes' : 'no' });
  if (u.pathname === '/csp-on') { self.cspMode = true; e.respondWith(new Response('ok')); return; }
  if (u.pathname === '/csp-off') { self.cspMode = false; e.respondWith(new Response('ok')); return; }
  if (u.pathname === '/seen') { e.respondWith(new Response(JSON.stringify(seen), { headers: { 'content-type': 'application/json' } })); return; }
  const m = u.pathname.match(/^\/app\/root\/(.*)$/);
  if (m) {
    const f = files[m[1]];
    const h = { 'content-type': f ? f[0] : 'text/plain', 'access-control-allow-origin': '*' };
    if (u.searchParams.get('csp') === '1' || (f && f[0] === 'text/html' && self.cspMode)) h['content-security-policy'] = 'sandbox allow-scripts';
    e.respondWith(f ? new Response(f[1], { headers: h })
                    : new Response('not in the tree', { status: 404 }));
    return;
  }
  if (u.pathname.startsWith('/app/other/')) { e.respondWith(new Response('another tree', { headers: { 'access-control-allow-origin': '*' } })); return; }
});
