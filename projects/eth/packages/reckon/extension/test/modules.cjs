// Apps built from ES modules, in the sandbox loader (build-doc.js): a fixture tree put in the extension's storage and
// shown, as an admitted one is. Static imports (with a cycle), a bare specifier through the app's own import map,
// import() of a literal and of a computed tree URL, fetch through import.meta.url, and a module worker importing a
// module of its own; and every way out still refused: an import and a worker from the network, with a listener on
// 127.0.0.1:PORT counting what reached it.
//
//     node packages/reckon/extension/test/modules.cjs [PORT]
const { chromium } = require('playwright');
const http = require('http');
const path = require('path');

const port = Number(process.argv[2] || 8897);
const NET = `http://127.0.0.1:${port}`;
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

const app = {
  'index.html': `<!doctype html><meta charset=utf-8><title>modules</title>
<script type="importmap">{ "imports": { "util": "./js/util.mjs" } }</script>
<script type="module" src="js/main.mjs"></script>`,
  'js/main.mjs': `
import { add } from './lib/math.mjs';
import { a } from './lib/a.mjs';
import { u } from 'util';
const r = (k, v) => parent.postMessage({ report: k, value: v }, '*');
r('static', add(2, 3));
r('cycle', a());
r('bare', u());
import('./lazy.mjs').then((m) => r('dynamic', m.lazy()), (e) => r('dynamic', 'error ' + e));
const name = 'computed';
import(new URL(\`./\${name}.mjs\`, import.meta.url)).then((m) => r('computed', m.v), (e) => r('computed', 'error ' + e));
fetch(new URL('../data/x.json', import.meta.url)).then((x) => x.json()).then((j) => r('meta-fetch', j.v), (e) => r('meta-fetch', 'error ' + e));
fetch(new URL('data/x.json', location.href)).then((x) => x.json()).then((j) => r('location-fetch', j.v), (e) => r('location-fetch', 'error ' + e));
const w = new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module' });
w.onmessage = (e) => r('worker', e.data);
w.onerror = (e) => r('worker', 'error ' + (e.message || e));
import('${NET}/evil.mjs').then(() => r('import-net', 'reached'), () => r('import-net', 'refused'));
try { new Worker('${NET}/w.js'); r('worker-net', 'created'); } catch (e) { r('worker-net', 'refused'); }
`,
  'js/lib/math.mjs': `export const add = (a, b) => a + b;`,
  'js/lib/a.mjs': `import { b } from './b.mjs'; export const tag = 'A'; export const a = () => 'a' + b();`,
  'js/lib/b.mjs': `import { tag } from './a.mjs'; export const b = () => 'b' + tag;`,
  'js/util.mjs': `export const u = () => 'util';`,
  'js/lazy.mjs': `import { add } from './lib/math.mjs'; export const lazy = () => add(10, 1);`,
  'js/computed.mjs': `export const v = 'computed';`,
  'js/worker.mjs': `import { add } from './lib/math.mjs'; postMessage(add(20, 1));`,
  'data/x.json': `{"v":"json"}`,
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
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(`chrome-extension://${id}/page.html`);
  const shown = await page.evaluate(async (files) => {
    const { writeTree, openTree } = await import('./tree.js');
    await writeTree('bafymodules', new Map(Object.entries(files).map(([p, t]) => [p, new TextEncoder().encode(t)])));
    window.__got = {};
    addEventListener('message', (e) => { if (e.data && e.data.report) window.__got[e.data.report] = e.data.value; });
    const s = await window.__reckon.show(await openTree('bafymodules'));
    return s.notes;
  }, app);
  await page.waitForTimeout(2500);
  const got = await page.evaluate(() => window.__got);
  console.log('   | ' + JSON.stringify(got));
  if (shown.length) console.log('   | notes: ' + shown.join('; '));
  ok(got.static === 5, 'a static import, resolved in the tree');
  ok(got.cycle === 'abA', 'a cycle between two modules');
  ok(got.bare === 'util', "a bare specifier, through the app's own import map");
  ok(got.dynamic === 11, 'import() of a literal path, and that module\'s own import');
  ok(got.computed === 'computed', 'import() of a URL computed from import.meta.url');
  ok(got['meta-fetch'] === 'json', 'fetch of a URL computed from import.meta.url, answered from the tree');
  ok(got['location-fetch'] === 'json', 'fetch of a name resolved against location.href (a wac-web page\'s site), answered from the tree');
  ok(got.worker === 21, 'a module worker from the tree, importing a module of its own');
  ok(got['import-net'] === 'refused', 'an import from the network: refused');
  ok(got['worker-net'] === 'refused', 'a worker from the network: refused');
  await page.waitForTimeout(500);
  ok(hits.length === 0, `nothing reached the network (${hits.length ? hits.join(', ') : 'no request'})`);
  ok(shown.length === 1 && /outside the tree, so not loaded: http:\/\/127\.0\.0\.1:\d+\/evil\.mjs$/.test(shown[0]),
     `what it says it could not load: the import from the network, once, and nothing else (${shown.join('; ')})`);
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close(); srv.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
