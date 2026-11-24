// The turbostack duel page in the extension (tools/turbostack.sh): SUBJECT opened from the page's own form with
// SETTINGS, admitted, the site CID fetched and checked, then run in the sandbox loader: it finds both models' weights
// beside it, and the two players place pieces. Screenshots into SHOTS.
//
//     node turbostack.cjs SETTINGS SUBJECT CID SHOTS
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const [settingsFile, subject, cid, shots] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
let pass = 0, fail = 0;
const ok = (c, what) => { if (c) { pass++; console.log(`ok    ${what}`); } else { fail++; console.log(`FAIL  ${what}`); } };

(async () => {
  const ext = path.resolve(__dirname, '../src');
  const ctx = await chromium.launchPersistentContext('', { channel: 'chromium', headless: true, viewport: { width: 980, height: 1000 },
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
  ok(/written below trees\//.test(account), "the site fetched from the mirror into the extension's storage, every block checked");
  if (!/^ADMITTED$/m.test(account)) {
    console.log('   | the whole account:\n   | ' + account.split('\n').join('\n   | '));
    await ctx.close();
    console.log(`\n${pass} passed, ${fail} failed`);
    process.exit(1);
  }

  let frame = null;
  for (let i = 0; i < 50 && !frame; i++) { frame = page.frames().find((f) => f.url().endsWith('/loader.html')) || null; if (!frame) await page.waitForTimeout(100); }
  ok(frame !== null, 'the page runs in the sandbox loader');
  // Each card's status line reads "N pieces" once its player is placing them; the page says so if the weights are missing.
  const counts = () => frame.evaluate(() => [...document.querySelectorAll('.status')].map((e) => {
    const m = /^(\d+) pieces$|after (\d+) pieces/.exec(e.textContent || ''); return m ? Number(m[1] || m[2]) : (/Finished/.test(e.textContent) ? 1e9 : -1);
  }));
  const playing = await frame.waitForFunction(() => {
    const s = [...document.querySelectorAll('.status')].map((e) => e.textContent || '');
    return /weights are not on this site/.test(document.body.textContent) || (s.length === 2 && s.every((t) => /\d+ pieces|Finished/.test(t)));
  }, null, { timeout: 60000 }).then(() => true, () => false);
  const missing = await frame.evaluate(() => /weights are not on this site/.test(document.body.textContent));
  ok(playing && !missing, `both models' weights found beside the page, and both players placing pieces (${((Date.now() - t0) / 1000).toFixed(1)} s from the click)`);
  const inside = await frame.evaluate(() => ({ origin: String(self.origin),
    api: typeof chrome !== 'undefined' && !!(chrome.runtime || chrome.storage || chrome.tabs) }));
  ok(inside.origin === 'null' && !inside.api, `it holds no extension API, and its origin is opaque (${inside.origin})`);
  const first = await counts();
  await page.waitForTimeout(3000);
  const later = await counts();
  ok(first.length === 2 && later.every((n, k) => n > first[k] || n === 1e9), `the game moves: pieces ${first.join(' / ')} → ${later.join(' / ')}`);
  await page.screenshot({ path: path.join(shots, 'admitted.png') });
  // The fastest speed, then a while later the duel well under way.
  const buttons = frame.locator('.speeds button');
  if (await buttons.count() > 0) await buttons.nth((await buttons.count()) - 1).click();
  await page.waitForTimeout(8000);
  const fast = await counts();
  console.log(`   | after the fastest speed for 8 s: pieces ${fast.join(' / ')}`);
  await page.screenshot({ path: path.join(shots, 'playing.png') });
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
