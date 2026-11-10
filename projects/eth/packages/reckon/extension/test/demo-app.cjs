// The demo app in the extension (tools/demo-app.sh): SUBJECT opened from the page's own form with SETTINGS, admitted,
// the page CID fetched and checked, then run in the sandbox loader: it draws, a click zooms, it holds no extension API.
// Screenshots into SHOTS.
//
//     node demo-app.cjs SETTINGS SUBJECT CID SHOTS
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const [settingsFile, subject, cid, shots] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

(async () => {
  const ext = path.resolve(__dirname, '../src');
  const ctx = await chromium.launchPersistentContext('', { channel: 'chromium', headless: true, viewport: { width: 980, height: 900 },
    deviceScaleFactor: 2, args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
  let [sw] = ctx.serviceWorkers();
  if (!sw) sw = await ctx.waitForEvent('serviceworker');
  const id = sw.url().split('/')[2];
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(`chrome-extension://${id}/page.html`);
  await page.evaluate((s) => chrome.storage.local.set({ settings: s }), settings);
  await page.reload();
  await page.fill('#subject', subject);
  const t0 = Date.now();
  await page.click('#open button');
  await page.waitForFunction(() => /^(ADMITTED|REFUSED)$/m.test(document.getElementById('account').textContent), null, { timeout: 180000 });
  const account = await page.evaluate(() => document.getElementById('account').textContent);
  console.log('   | ' + account.split('\n').filter((l) => /^name:|^chain:|^as of|^web: admitted|ADMITTED|REFUSED|written/.test(l)).join('\n   | '));
  ok(/^ADMITTED$/m.test(account) && account.includes(`web: admitted ${cid}`), `${subject} read by proof, admitted, and it is ${cid.slice(0, 16)}…`);
  ok(/written below trees\//.test(account), "the page fetched from the mirror into the extension's storage, every block checked");

  // The app, in the sandbox loader's frame.
  let frame = null;
  for (let i = 0; i < 50 && !frame; i++) { frame = page.frames().find((f) => f.url().endsWith('/loader.html')); if (!frame) await page.waitForTimeout(100); }
  ok(frame !== null, 'the app runs in the sandbox loader');
  const drawn = await frame.waitForFunction(() => /\d+ pixels in \d+ ms/.test((document.getElementById('took') || {}).textContent || ''), null, { timeout: 30000 })
    .then(() => true, () => false);
  const took = await frame.evaluate(() => (document.getElementById('took') || {}).textContent);
  ok(drawn, `it draws: "${took}" (${((Date.now() - t0) / 1000).toFixed(1)} s from the click to a picture)`);
  const inside = await frame.evaluate(() => ({ origin: String(self.origin),
    api: typeof chrome !== 'undefined' && !!(chrome.runtime || chrome.storage || chrome.tabs) }));
  ok(inside.origin === 'null' && !inside.api, `it holds no extension API, and its origin is opaque (${inside.origin})`);
  const picture = () => frame.evaluate(() => {
    const c = document.getElementById('c');
    const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    let h = 0, lit = 0;
    for (let i = 0; i < d.length; i += 4) { h = (h * 31 + d[i] + d[i + 1] * 7 + d[i + 2] * 13) >>> 0; if (d[i + 2] > 60) lit++; }
    return { h, lit };
  });
  const before = await picture();
  ok(before.lit > 1000, `the picture is a Mandelbrot set, not a blank canvas (${before.lit} bright pixels)`);
  await page.screenshot({ path: path.join(shots, 'admitted.png') });
  const box = await frame.locator('#c').boundingBox();
  await frame.locator('#c').click({ position: { x: box.width * 0.30, y: box.height * 0.42 } });
  await frame.waitForFunction((h) => {
    const c = document.getElementById('c'); const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    let x = 0; for (let i = 0; i < d.length; i += 4) x = (x * 31 + d[i] + d[i + 1] * 7 + d[i + 2] * 13) >>> 0; return x !== h;
  }, before.h, { timeout: 15000 }).catch(() => {});
  const after = await picture();
  ok(after.h !== before.h, 'a click zooms in: the app is running, not a picture of one');
  await page.screenshot({ path: path.join(shots, 'zoomed.png') });
  await frame.locator('#c').click({ position: { x: box.width * 0.62, y: box.height * 0.30 } });
  await page.waitForTimeout(800);
  await page.screenshot({ path: path.join(shots, 'zoomed2.png') });
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
