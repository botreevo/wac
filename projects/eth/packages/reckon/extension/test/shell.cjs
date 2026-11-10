// Milestone 2's shell under Playwright's Chromium (docs/browser-extension.md): the extension loads; its page is
// cross-origin isolated (SharedArrayBuffer, for the admission worker); with no settings, admission does not admit and
// nothing is shown; and an app tree put in OPFS is shown through the sandbox loader, with every reference into the
// tree working and every way out failing. A listener on 127.0.0.1:PORT counts what reached the network. Needs the
// admission build (extension/build.sh); admit.sh is the test of admission itself.
//
//     node packages/reckon/extension/test/shell.cjs [PORT]
const { chromium } = require('playwright');
const http = require('http');
const path = require('path');

const port = Number(process.argv[2] || 8898);
const NET = `http://127.0.0.1:${port}`;
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

const app = {
  'index.html': `<!doctype html><meta charset=utf-8><title>fixture</title>
<link rel=stylesheet href="css/site.css"><link rel=icon href="favicon.svg">
<script src="${NET}/outside.js"></script>
<img id=logo src="img/logo.svg" srcset="img/logo.svg 1x, img/logo.svg 2x">
<p style="background-image: url('img/logo.svg')">hello</p>
<a id=next href="sub/about.html">about</a>
<script src="js/main.js"></script>`,
  'css/site.css': `@import "more.css"; body { background: url(../img/logo.svg) no-repeat; color: rgb(1, 2, 3); }`,
  'css/more.css': `p { color: rgb(4, 5, 6); }`,
  'img/logo.svg': `<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>`,
  'favicon.svg': `<svg xmlns="http://www.w3.org/2000/svg"/>`,
  'data/x.json': `{"from":"the tree"}`,
  'js/main.js': `
const r = (k, v) => parent.postMessage({ report: k, value: v }, '*');
r('origin', String(self.origin));
r('extension-api', typeof chrome !== 'undefined' && (chrome.runtime || chrome.storage || chrome.tabs) ? 'yes' : 'no');
r('color', getComputedStyle(document.body).color);
r('p-color', getComputedStyle(document.querySelector('p')).color);
addEventListener('load', () => r('logo', document.getElementById('logo').naturalWidth));
fetch('data/x.json').then(x => x.json()).then(j => r('fetch', j.from), e => r('fetch', 'error ' + e));
fetch('/missing.json').then(x => r('fetch-missing', x.status), e => r('fetch-missing', 'error'));
fetch('${NET}/fetch').then(x => r('fetch-net', 'reached'), e => r('fetch-net', 'refused'));
const x = new XMLHttpRequest(); x.open('GET', 'data/x.json'); x.onload = () => r('xhr', JSON.parse(x.responseText).from); x.send();
const y = new XMLHttpRequest(); y.open('GET', '${NET}/xhr'); y.onerror = () => r('xhr-net', 'refused'); y.onload = () => r('xhr-net', 'reached'); y.send();
const im = new Image(); im.onerror = () => r('img-net', 'refused'); im.onload = () => r('img-net', 'reached'); im.src = '${NET}/img';
try { navigator.sendBeacon('${NET}/beacon', 'x'); } catch (e) {}
try { new WebSocket('ws://127.0.0.1:${port}/ws'); } catch (e) {}
r('done', 'index');
`,
  'sub/about.html': `<!doctype html><meta charset=utf-8><link rel=stylesheet href="../css/site.css"><body><p>about</p>
<script>parent.postMessage({ report: 'about-color', value: getComputedStyle(document.body).color }, '*');</script>`,
};

(async () => {
  const hits = [];
  const srv = http.createServer((q, s) => { hits.push(q.url); s.end('x'); }).listen(port, '127.0.0.1');
  const ext = path.resolve(__dirname, '../src');
  const ctx = await chromium.launchPersistentContext('', { channel: 'chromium', headless: true,
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const id = sw.url().split('/')[2];
  ok(/^[a-p]{32}$/.test(id), `the extension loads (${id})`);

  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  // No mirrors (the default, a public gateway, is not what this checks), and nothing else set.
  await page.goto(`chrome-extension://${id}/page.html`);
  await page.evaluate(() => chrome.storage.local.set({ settings: { mirrors: '' } }));
  await page.goto(`chrome-extension://${id}/page.html?open=${encodeURIComponent('ens:vitalik.eth')}`);
  await page.waitForTimeout(500);
  ok(await page.evaluate(() => crossOriginIsolated && typeof SharedArrayBuffer === 'function'),
     'the page is cross-origin isolated: SharedArrayBuffer, for the admission worker');
  await page.waitForFunction(() => !/^admitting/.test(document.getElementById('account').textContent), null, { timeout: 120000 });
  const acct = await page.evaluate(() => document.getElementById('account').textContent);
  ok(!/^ADMITTED$/m.test(acct) && /give --checkpoint to start it/.test(acct), 'with no settings, admission admits nothing, and says what it lacks (a checkpoint)');
  ok(!(await page.evaluate(() => document.getElementById('app').classList.contains('shown'))), '…and nothing is shown');

  // A tree as admission will leave it in OPFS, and shown as an admitted one is.
  const reports = await page.evaluate(async (files) => {
    const { writeTree, openTree } = await import('./tree.js');
    await writeTree('bafyfixture', new Map(Object.entries(files).map(([p, t]) => [p, new TextEncoder().encode(t)])));
    const got = {};
    addEventListener('message', (e) => { if (e.data && e.data.report) got[e.data.report] = e.data.value; });
    const tree = await openTree('bafyfixture');
    const shown = await window.__reckon.show(tree);
    window.__got = got;
    return { paths: tree.paths, notes: shown.notes };
  }, app);
  ok(reports.paths.length === Object.keys(app).length, `the tree read back from OPFS: ${reports.paths.length} files`);
  ok(reports.notes.some((n) => n.includes(`${NET}/outside.js`)), 'a script outside the tree is named as not loaded');
  await page.waitForTimeout(2000);
  const got = await page.evaluate(() => window.__got);
  ok(got.origin === 'null', `the app's origin is opaque (${got.origin})`);
  ok(got['extension-api'] === 'no', 'the app holds no extension API');
  ok(got.color === 'rgb(1, 2, 3)' && got['p-color'] === 'rgb(4, 5, 6)', 'its stylesheet, and the one that imports, apply');
  ok(got.logo > 0, `its image loads from the tree, srcset and all (natural width ${got.logo})`);
  ok(got.fetch === 'the tree' && got.xhr === 'the tree', 'fetch and XHR within the tree are answered');
  ok(got['fetch-missing'] === 404, 'a path not in the tree is a 404');
  ok(got['fetch-net'] === 'refused' && got['xhr-net'] === 'refused' && got['img-net'] === 'refused', 'fetch, XHR and an image outside: refused');

  await page.evaluate(() => { window.__got = {}; addEventListener('message', (e) => { if (e.data && e.data.report) window.__got[e.data.report] = e.data.value; }); });
  await page.frameLocator('#app').locator('#next').click();
  await page.waitForTimeout(1500);
  const nav = await page.evaluate(() => window.__got);
  ok(nav['about-color'] === 'rgb(1, 2, 3)', 'a link within the tree opens that page in a fresh loader, its stylesheet (../css) from the tree');

  await page.waitForTimeout(500);
  ok(hits.length === 0, `nothing reached the network (${hits.length ? hits.join(', ') : 'no request'})`);
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
