// The spike of docs/browser-extension.md: how an MV3 extension can show an admitted app so that it holds no extension
// API and reaches nothing outside its tree. Five ways, one per case; run with `node run.cjs` while `node hits.mjs`
// listens on 127.0.0.1:8899 to show whether anything the app tries reaches the network. Results are in the doc.
const { chromium } = require('playwright');
const path = require('path');
(async () => {
  const ext = path.resolve(__dirname, 'ext');
  const ctx = await chromium.launchPersistentContext('', { channel: 'chromium', headless: true,
    args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const id = sw.url().split('/')[2];
  // [frame sandbox attribute, CSP sandbox header from the worker, page, through the packaged sandbox loader]
  const cases = [['allow-scripts', 0, 'index.html', 0], ['allow-scripts allow-same-origin', 0, 'index.html', 0],
                 ['none', 1, 'index.html', 0], ['none', 1, 'inline.html', 0], ['none', 0, 'inline.html', 1]];
  for (const [sandbox, csp, pg, loader] of cases) {
    const before = await sw.evaluate(() => seen.length);
    const page = await ctx.newPage();
    const errs = [];
    page.on('console', (m) => errs.push(m.text()));
    await page.goto(`chrome-extension://${id}/host.html?sandbox=${encodeURIComponent(sandbox)}&page=${pg}&csp=${csp}&loader=${loader}`);
    await page.waitForTimeout(3000);
    const results = await page.evaluate(() => window.results);
    console.log(`\n== frame sandbox attribute "${sandbox}", CSP sandbox header ${csp ? 'yes' : 'no'}, page ${pg}`);
    for (const r of results) console.log(`  ${r.k}: ${r.v}`);
    const seen = await sw.evaluate(() => seen);
    console.log('  service worker saw:', seen.slice(before).map(s => `${s.path} (${s.dest || 'fetch'})`).join(', ') || 'nothing');
    if (errs.length) console.log('  console:', [...new Set(errs)].join(' | '));
    await page.close();
  }
  await ctx.close();
})();
