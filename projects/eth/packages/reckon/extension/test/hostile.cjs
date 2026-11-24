// A hostile app in the sandbox loader: an admitted tree whose pages try every way out we know of, each one aimed at its
// own path on a listener at 127.0.0.1:PORT (TCP, and UDP for WebRTC's STUN). For each way out the test records what the
// app saw, any CSP violation the browser reported (its directive), and whether anything reached the listener. A way out
// passes when nothing reached the network and the app got nothing it should not have. Writes a table, one line per way
// out with what stopped it, to OUT (JSON) when given.
//
//     node packages/reckon/extension/test/hostile.cjs [PORT] [OUT]
const { chromium } = require('playwright');
const http = require('http');
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');

const port = Number(process.argv[2] || 8897);
const outFile = process.argv[3] || '';
const NET = `http://127.0.0.1:${port}`;
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

// Every page reports to its parent (the extension page) as { report, value }, and CSP violations as { csp: directive }.
const REPORT = `
const r = (k, v) => parent.postMessage({ report: k, value: String(v) }, '*');
addEventListener('securitypolicyviolation', (e) => parent.postMessage({ csp: e.effectiveDirective || e.violatedDirective, uri: e.blockedURI }, '*'));
const tryIt = async (k, f) => { try { r(k, await f()); } catch (e) { r(k, (e && e.name ? e.name + ': ' : '') + (e && e.message ? e.message : e)); } };
`;

// The ways out that leave the page where it is, run in order from the index page.
const index = `<!doctype html><meta charset=utf-8><title>hostile</title>
<style>@import url("${NET}/v/css-import"); @font-face { font-family: x; src: url("${NET}/v/font"); }
  body { background: url("${NET}/v/css-url"); font-family: x; }</style>
<link rel=prefetch href="${NET}/v/prefetch"><link rel=preload as=fetch href="${NET}/v/preload">
<link rel=stylesheet href="${NET}/v/stylesheet">
<script src="${NET}/v/script"></script>
<img src="${NET}/v/img"><video src="${NET}/v/video"></video><audio src="${NET}/v/audio"></audio>
<object data="${NET}/v/object"></object><embed src="${NET}/v/embed">
<iframe src="${NET}/v/iframe"></iframe><iframe srcdoc="<script>try { const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:${port}' }] }); pc.createDataChannel('x'); pc.createOffer().then((o) => pc.setLocalDescription(o)); parent.postMessage({ report: 'webrtc-srcdoc', value: 'constructed in a srcdoc frame' }, '*'); } catch (e) { parent.postMessage({ report: 'webrtc-srcdoc', value: e.name + ': ' + e.message }, '*'); }<\\/script>"></iframe><iframe srcdoc="<script>fetch('${NET}/v/srcdoc-fetch')<\\/script>"></iframe>
<p>hostile</p>
<script>${REPORT}
(async () => {
  await tryIt('fetch', async () => (await fetch('${NET}/v/fetch')).status);
  await tryIt('fetch-no-cors', async () => (await fetch('${NET}/v/fetch-no-cors', { mode: 'no-cors' })).type);
  await tryIt('xhr', () => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open('GET', '${NET}/v/xhr'); x.onload = () => ok('loaded ' + x.status); x.onerror = () => ok('error event'); x.send(); }));
  await tryIt('websocket', () => new Promise((ok) => { const w = new WebSocket('ws://127.0.0.1:${port}/v/websocket'); w.onopen = () => ok('open'); w.onerror = () => ok('error event'); }));
  await tryIt('eventsource', () => new Promise((ok) => { const s = new EventSource('${NET}/v/eventsource'); s.onopen = () => ok('open'); s.onerror = () => { s.close(); ok('error event'); }; }));
  await tryIt('beacon', () => navigator.sendBeacon('${NET}/v/beacon', 'x') ? 'queued' : 'refused');
  await tryIt('dynamic-import', async () => { await import('${NET}/v/import.js'); return 'imported'; });
  await tryIt('worker-net', () => new Promise((ok) => { const w = new Worker('${NET}/v/worker.js'); w.onerror = () => ok('error event'); setTimeout(() => ok('no answer'), 1500); }));
  await tryIt('blob-worker-fetch', () => new Promise((ok) => {
    const src = "fetch('${NET}/v/blob-worker-fetch').then(()=>postMessage('reached'),e=>postMessage('refused: '+e.message))";
    const w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
    w.onmessage = (e) => ok(e.data); w.onerror = (e) => ok('worker error: ' + (e.message || 'blocked')); setTimeout(() => ok('no answer'), 2000); }));
  await tryIt('service-worker', async () => { await navigator.serviceWorker.register('sw.js'); return 'registered'; });
  await tryIt('webrtc-stun', () => new Promise((ok) => {
    const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:${port}' }] });
    pc.createDataChannel('x'); pc.createOffer().then((o) => pc.setLocalDescription(o));
    pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') ok('gathering complete'); };
    setTimeout(() => ok('gathering ' + pc.iceGatheringState), 3000); }));
  await tryIt('webrtc-blank-frame', () => new Promise((ok) => {
    const f = document.createElement('iframe'); document.body.append(f);
    const W = f.contentWindow && f.contentWindow.RTCPeerConnection;
    if (typeof W !== 'function') { ok('no RTCPeerConnection in a fresh frame (' + typeof W + ')'); return; }
    const pc = new W({ iceServers: [{ urls: 'stun:127.0.0.1:${port}?blank' }] });
    pc.createDataChannel('x'); pc.createOffer().then((o) => pc.setLocalDescription(o));
    setTimeout(() => ok('constructed in a fresh frame; gathering ' + pc.iceGatheringState), 3000); }));
  await tryIt('webrtc-window-index', () => new Promise((ok) => {
    const f = document.createElement('iframe'); document.body.append(f);
    const W = window[window.length - 1].RTCPeerConnection;
    if (typeof W !== 'function') { ok('no RTCPeerConnection through window[N] (' + typeof W + ')'); return; }
    const pc = new W({ iceServers: [{ urls: 'stun:127.0.0.1:${port}?index' }] });
    pc.createDataChannel('x'); pc.createOffer().then((o) => pc.setLocalDescription(o));
    setTimeout(() => ok('constructed through window[N]; gathering ' + pc.iceGatheringState), 3000); }));
  await tryIt('webrtc-srcdoc-dynamic', () => new Promise((ok) => {
    const f = document.createElement('iframe'); document.body.append(f);
    f.srcdoc = "<script>try { new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:${port}' }] }).createDataChannel('x'); } catch (e) {}<\\/script>";
    setTimeout(() => ok('sandbox now "' + f.getAttribute('sandbox') + '"'), 2500); }));
  await tryIt('webrtc-unsandbox', () => new Promise((ok) => {
    const f = document.createElement('iframe'); document.body.append(f);
    setTimeout(() => { f.setAttribute('sandbox', 'allow-scripts'); f.srcdoc = "<script>new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:${port}' }] }).createDataChannel('x')<\\/script>"; }, 50);
    setTimeout(() => ok('sandbox now "' + f.getAttribute('sandbox') + '"'), 2500); }));
  await tryIt('javascript-frame', () => new Promise((ok) => {
    const src = "<script>new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:${port}' }] }).createDataChannel('x')<\\/script>";
    const f = document.createElement('iframe'); f.src = 'javascript:' + encodeURIComponent(JSON.stringify(src)); document.body.append(f);
    setTimeout(() => ok('sandbox now "' + f.getAttribute('sandbox') + '"'), 2500); }));
  await tryIt('local-storage', () => { localStorage.setItem('k', 'v'); return 'stored'; });
  await tryIt('indexeddb', () => new Promise((ok) => { const q = indexedDB.open('x'); q.onsuccess = () => ok('opened'); q.onerror = () => ok('error: ' + (q.error && q.error.name)); }));
  await tryIt('cookie', () => { document.cookie = 'k=v'; return document.cookie === '' ? 'no cookie kept' : 'kept: ' + document.cookie; });
  await tryIt('parent-dom', () => parent.document.title);
  await tryIt('top-dom', () => top.location.href);
  await tryIt('extension-api', () => typeof chrome !== 'undefined' && (chrome.runtime || chrome.storage || chrome.tabs) ? 'present' : 'absent');
  await tryIt('popup', () => { const w = window.open('${NET}/v/popup'); return w ? 'opened' : 'null'; });
  await tryIt('ask-outside-tree', () => new Promise((ok) => {
    const id = 'h1'; addEventListener('message', function on(e) { if (e.data && e.data.id === id) { removeEventListener('message', on); ok(e.data.status); } });
    parent.postMessage({ id, ask: '../../manifest.json' }, '*'); setTimeout(() => ok('no answer'), 1000); }));
  await tryIt('ask-other-tree', () => new Promise((ok) => {
    const id = 'h2'; addEventListener('message', function on(e) { if (e.data && e.data.id === id) { removeEventListener('message', on); ok(e.data.status); } });
    parent.postMessage({ id, ask: '/trees/bafyother/secret.txt' }, '*'); setTimeout(() => ok('no answer'), 1000); }));
  await tryIt('navigate-outside-tree', () => { parent.postMessage({ navigate: '${NET}/v/navigate-message' }, '*'); return 'asked'; });
  await tryIt('form-post', () => { const f = document.createElement('form'); f.method = 'post'; f.action = '${NET}/v/form'; f.target = 'sink';
    const i = document.createElement('iframe'); i.name = 'sink'; document.body.append(i, f); f.submit(); return 'submitted'; });
  setTimeout(() => r('done', 'index'), 1500);
})();
</script>`;

// The ways out that would take the page somewhere else: each its own page, shown alone.
const nav = (k, body) => `<!doctype html><meta charset=utf-8><title>${k}</title><p>${k}</p><script>${REPORT}
${body}
setTimeout(() => r('${k}', 'still here'), 1500);</script>`;
const pages = {
  'nav-self.html': nav('nav-self', `try { location.href = '${NET}/v/nav-self'; } catch (e) { r('nav-self', e.name + ': ' + e.message); }`),
  'nav-top.html': nav('nav-top', `try { top.location.href = '${NET}/v/nav-top'; } catch (e) { r('nav-top', e.name + ': ' + e.message); }`),
  'nav-meta.html': `<!doctype html><meta charset=utf-8><meta http-equiv=refresh content="0; url=${NET}/v/nav-meta"><p>meta</p>
<script>${REPORT} setTimeout(() => r('nav-meta', 'still here'), 1500);</script>`,
  'nav-link.html': nav('nav-link', `const a = document.createElement('a'); a.href = '${NET}/v/nav-link'; document.body.append(a); a.click();`),
  'nav-base.html': `<!doctype html><meta charset=utf-8><base href="${NET}/v/"><a id=a href="nav-base">x</a>
<script>${REPORT} document.getElementById('a').click(); setTimeout(() => r('nav-base', 'still here'), 1500);</script>`,
  'nav-blank.html': nav('nav-blank', `const a = document.createElement('a'); a.href = '${NET}/v/nav-blank'; a.target = '_blank'; document.body.append(a); a.click();`),
  'nav-download.html': nav('nav-download', `const a = document.createElement('a'); a.href = 'data:text/plain,x'; a.download = 'x.txt'; document.body.append(a); a.click(); r('nav-download-tried', 'clicked');`),
};

// What stops each way out, as the extension is built: what the test expects to see, and says on the site.
const BY = {
  'css-import': "CSP style-src (data: and inline only)", font: "CSP font-src 'data:'", 'css-url': "CSP img-src 'data:'",
  prefetch: "CSP default-src 'none' (prefetch)", preload: "CSP connect-src 'none'", stylesheet: 'CSP style-src', script: 'CSP script-src (inline, data: and blob: only)',
  img: "CSP img-src 'data:'", video: "CSP media-src 'data:'", audio: "CSP media-src 'data:'", object: "CSP default-src 'none' (object-src)",
  embed: "CSP default-src 'none' (object-src)", iframe: "CSP frame-src 'none'", 'srcdoc-fetch': "the loader's shim: a frame with its own document loads without scripts (and inherits connect-src 'none')",
  fetch: "the loader's shim (fetch answers names in the tree only), with CSP connect-src 'none' behind it",
  'fetch-no-cors': "the loader's shim, with CSP connect-src 'none' behind it", xhr: "the loader's shim (XHR answers names in the tree only), with CSP connect-src 'none' behind it", websocket: "CSP connect-src 'none'",
  eventsource: "CSP connect-src 'none'", beacon: "CSP connect-src 'none'", 'dynamic-import': 'CSP script-src-elem', 'worker-net': "the loader's shim (a worker only from a module of the tree), with CSP behind it",
  'blob-worker-fetch': "the worker inherits the page's CSP: connect-src 'none'", 'service-worker': 'the opaque origin (no service workers)',
  'webrtc-stun': "the loader's shim: no RTCPeerConnection (CSP does not cover WebRTC)",
  'webrtc-blank-frame': "the loader's shim, through the iframe element's contentWindow",
  'webrtc-window-index': 'the same-origin policy: a sandboxed frame\'s child has an opaque origin of its own',
  'webrtc-srcdoc': "the loader's shim: a frame with its own document loads without scripts (sandbox '')",
  'webrtc-srcdoc-dynamic': "the loader's shim, for a srcdoc set after the frame is in the page",
  'webrtc-unsandbox': "the loader's shim: a frame's sandbox loosened is put back, and the frame reloaded",
  'javascript-frame': "the loader's shim (sandbox '' for every frame)", 'local-storage': 'the opaque origin (no storage)',
  indexeddb: 'the opaque origin (no storage)', cookie: 'the opaque origin (no cookies)', 'parent-dom': 'the same-origin policy (opaque origin)',
  'top-dom': 'the same-origin policy (opaque origin)', 'extension-api': 'a sandboxed page has no extension API', popup: "the sandbox: no allow-popups",
  'ask-outside-tree': 'page.js answers names in the shown tree only', 'ask-other-tree': 'page.js answers names in the shown tree only',
  'navigate-message': 'page.js shows only a page in the shown tree', form: "CSP form-action 'none'",
  'nav-self': "the fence: the tab's session rule blocks every request the extension did not make (page.js); CSP has no navigate-to", 'nav-top': 'the sandbox: no allow-top-navigation', 'nav-meta': 'the sandbox: a refresh to another origin is not followed',
  'nav-link': "the loader's shim, which routes links to names in the tree", 'nav-base': "the loader's shim (and base-uri)",
  'nav-blank': 'the sandbox: no allow-popups', 'nav-download': 'the sandbox: no allow-downloads',
};

(async () => {
  const hits = [];
  const udp = [];
  const srv = http.createServer((q, s) => { hits.push(q.url); s.setHeader('access-control-allow-origin', '*'); s.end('x'); }).listen(port, '127.0.0.1');
  srv.on('upgrade', (q, sock) => { hits.push(q.url); sock.destroy(); });
  const stun = dgram.createSocket('udp4'); stun.on('message', (m) => udp.push(m.length)); stun.bind(port, '127.0.0.1');
  const ext = path.resolve(__dirname, '../src');
  const ctx = await chromium.launchPersistentContext('', { channel: 'chromium', headless: true,
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const id = sw.url().split('/')[2];
  const page = await ctx.newPage();
  const popups = [];
  ctx.on('page', (p) => popups.push(p.url()));
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message + (e.stack ? ' @ ' + e.stack.split('\n').slice(1, 3).join(' ') : '')));
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(m.text()));
  await page.goto(`chrome-extension://${id}/page.html`);
  const pageUrl = page.url();
  const tree = { 'index.html': index, ...pages, 'sw.js': 'self.onfetch = () => {};' };
  await page.evaluate(async (files) => {
    const { writeTree } = await import('./tree.js');
    await writeTree('bafyhostile', new Map(Object.entries(files).map(([p, t]) => [p, new TextEncoder().encode(t)])));
    await writeTree('bafyother', new Map([['secret.txt', new TextEncoder().encode('secret')]]));
    window.__got = {}; window.__csp = [];
    addEventListener('message', (e) => {
      if (!e.data) return;
      if (e.data.report) window.__got[e.data.report] = e.data.value;
      if (e.data.csp) window.__csp.push(e.data.csp + ' ' + e.data.uri);
    });
  }, tree);
  const showPage = async (p, wait) => {
    await page.evaluate(async (p) => { const { openTree } = await import('./tree.js'); await window.__reckon.show(await openTree('bafyhostile'), p); }, p);
    await page.waitForTimeout(wait);
  };
  await showPage('index.html', 0);
  await page.waitForFunction(() => window.__got.done === 'index', null, { timeout: 60000 }).catch(() => {});
  await page.waitForTimeout(1000);
  for (const p of Object.keys(pages)) await showPage(p, 2500);
  await page.waitForTimeout(1000);

  const got = await page.evaluate(() => window.__got);
  const csp = await page.evaluate(() => window.__csp);
  const reached = (k) => hits.some((h) => h.startsWith(`/v/${k}`));
  // A report on a frame or an object names only the origin it was kept from, not the path.
  const ORIGIN_ONLY = { iframe: 'frame-src', object: 'object-src', embed: 'object-src' };
  const cspFor = (k) => csp.filter((c) => c.includes(`/v/${k}`) || (ORIGIN_ONLY[k] && c === `${ORIGIN_ONLY[k]} ${NET}`)).map((c) => c.split(' ')[0]);
  const rows = [];
  const row = (k, sawOk, extra) => {
    const r = reached(k);
    const stoppedBy = cspFor(k);
    rows.push({ way: k, reached: r, saw: got[k] ?? null, csp: stoppedBy, by: BY[k] || '' });
    ok(!r && sawOk, `${k}: ${r ? 'REACHED the network' : 'nothing reached the network'}`
      + `${got[k] !== undefined ? `; the app saw "${got[k]}"` : ''}${stoppedBy.length ? `; CSP ${[...new Set(stoppedBy)].join(', ')}` : ''}${extra ? '; ' + extra : ''}`
      + (BY[k] ? `\n        stopped by ${BY[k]}` : ''));
  };
  for (const k of ['css-import', 'font', 'css-url', 'prefetch', 'preload', 'stylesheet', 'script', 'img', 'video', 'audio', 'object', 'embed', 'iframe', 'srcdoc-fetch'])
    row(k, true);
  const refused = (v) => v !== undefined && !/^(200|basic|opaque|loaded|open|imported|registered|reached|queued)/.test(v);
  for (const k of ['fetch', 'fetch-no-cors', 'xhr', 'websocket', 'eventsource', 'dynamic-import', 'worker-net', 'blob-worker-fetch', 'service-worker'])
    row(k, refused(got[k]));
  // sendBeacon answers true once it has queued the request, before CSP stops it: the violation is what says so.
  row('beacon', cspFor('beacon').includes('connect-src'));
  // UDP carries no path, so the three WebRTC ways out are told apart by what each saw: one that could not construct a
  // peer connection sent nothing.
  const noPc = (v) => v !== undefined && /^(TypeError|SecurityError|NotAllowedError|no RTCPeerConnection)/.test(v);
  for (const k of ['webrtc-stun', 'webrtc-blank-frame', 'webrtc-window-index']) row(k, noPc(got[k]));
  // A srcdoc frame reports to its own parent (the app), not to the test; that no UDP arrived is what says it ran no script.
  for (const k of ['webrtc-srcdoc', 'webrtc-srcdoc-dynamic', 'webrtc-unsandbox', 'javascript-frame']) row(k, udp.length === 0);
  ok(udp.length === 0, `no UDP at the listener (${udp.length} packet(s))`);
  row('local-storage', refused(got['local-storage']));
  row('indexeddb', got.indexeddb !== 'opened');
  row('cookie', got.cookie !== undefined && !/^kept/.test(got.cookie));
  row('parent-dom', got['parent-dom'] !== undefined && /SecurityError/.test(got['parent-dom']));
  row('top-dom', got['top-dom'] !== undefined && /SecurityError/.test(got['top-dom']));
  row('extension-api', got['extension-api'] === 'absent');
  row('popup', got.popup === 'null' && popups.length === 0, `${popups.length} page(s) opened`);
  row('ask-outside-tree', got['ask-outside-tree'] === '404');
  row('ask-other-tree', got['ask-other-tree'] === '404');
  row('navigate-message', true);
  row('form', true);
  for (const k of ['nav-self', 'nav-top', 'nav-meta', 'nav-link', 'nav-base', 'nav-blank']) row(k, true);
  row('nav-download', true, consoleLines.filter((l) => /download/i.test(l)).slice(0, 1).join(''));
  ok(page.url() === pageUrl, 'the extension page itself is where it was');
  ok(hits.length === 0, `nothing reached the listener at all (${hits.length ? hits.join(', ') : 'no request'})`);
  // The app's own failures (its refused requests, unhandled) are reported from its frames: only the page's count.
  const own = errors.filter((e) => !/about:srcdoc|about:blank|loader\.html/.test(e) && !/^(Failed to fetch|reckon: only the admitted tree)/.test(e));
  ok(own.length === 0, `no errors on the extension page itself${own.length ? ': ' + own.join('; ') : ''} (${errors.length - own.length} from the app's frames)`);
  if (outFile) fs.writeFileSync(outFile, JSON.stringify({ hits, udp: udp.length, csp, rows }, null, 2));
  await ctx.close(); srv.close(); stun.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
