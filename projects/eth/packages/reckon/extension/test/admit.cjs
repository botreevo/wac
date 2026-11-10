// The extension under Playwright's Chromium, with settings from SETTINGS (admit.sh): it admits and shows APP, refuses
// OTHER and shows nothing, and admits ens:vitalik.eth (the light client in the extension) though its content is on no
// mirror here; a later admission resumes the light client's kept state.
//
//     node admit.cjs SETTINGS APP OTHER VITALIK
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const [settingsFile, appCid, otherCid, vitalik] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

(async () => {
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
  await page.evaluate((s) => chrome.storage.local.set({ settings: s }), settings);
  await page.reload();

  // Open SUBJECT from the page's own form, as a person would; wait for admission to end.
  const open = async (subject) => {
    await page.evaluate(() => { window.__got = {}; window.__reckon.last = null;
      addEventListener('message', (e) => { if (e.data && e.data.report) window.__got[e.data.report] = e.data.value; }); });
    await page.fill('#subject', subject);
    const t0 = Date.now();
    await page.click('#open button');
    await page.waitForFunction(() => /ADMITTED|REFUSED|\[exit|not finish|written below|no source has/.test(document.getElementById('account').textContent)
      && !/^admitting/.test(document.getElementById('account').textContent), null, { timeout: 180000 });
    const ms = Date.now() - t0;
    console.log(`   | ${subject}: decided in ${(ms / 1000).toFixed(1)} s`);
    await page.waitForTimeout(1500);
    return page.evaluate((ms) => ({ ms, account: document.getElementById('account').textContent,
      asof: document.getElementById('asof').textContent, asofClass: document.getElementById('asof').className,
      shown: document.getElementById('app').classList.contains('shown'), got: window.__got, last: window.__reckon.last }), ms);
  };

  const a = await open(appCid);
  ok(/light client: finalized execution block 0xe6343fc3/.test(a.account), 'the extension runs the light client from the checkpoint, in its page');
  ok(/^ADMITTED$/m.test(a.account) && /written below trees\//.test(a.account), 'it admits the reviewed app, and writes it into the extension\'s storage from checked blocks');
  ok(a.last && a.last.cid === appCid && a.last.paths.length === 4, `the tree read back is the admitted CID's, ${a.last ? a.last.paths.length : 0} files`);
  ok(a.shown && a.got.origin === 'null', 'the app is shown through the sandbox loader, its origin opaque');
  ok(a.got.color === 'rgb(7, 8, 9)' && a.got.fetch === 'from its own tree', 'its stylesheet applies, and its fetch is answered from its tree');
  ok(/^Admitted as of beacon slot 15621760/.test(a.asof) && a.asofClass === 'stale',
     `the page says what it is as of, and that recorded data is old: "${a.asof.slice(0, 70)}…"`);

  const b = await open(otherCid);
  ok(/^REFUSED$/m.test(b.account) && /endorsed by nobody/.test(b.account), 'a tree nobody reviewed is refused, saying why');
  ok(!b.shown && b.last === null, '…and nothing is shown');
  ok(/resumed from its kept state/.test(b.account) && !/bootstrap/.test(b.account), 'this admission resumed the light client\'s kept state: no bootstrap');

  const c = await open('ens:vitalik.eth');
  ok(/name: vitalik\.eth → ipfs:\/\/bafybeia5eyom/.test(c.account) && /^ADMITTED$/m.test(c.account), 'ens:vitalik.eth: read by proof in the extension, and admitted');
  ok(/no source has/.test(c.account) && !c.shown, '…its content is on no mirror here: said, and nothing shown');

  ok(a.ms < 30000 && b.ms < 30000, `each admission in the extension decides within 30 s (from the checkpoint ${(a.ms / 1000).toFixed(1)} s, resumed ${(b.ms / 1000).toFixed(1)} s)`);
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
