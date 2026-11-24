// wac-chess in the extension (tools/chess.sh): SUBJECT opened from the page's own form with SETTINGS, admitted, the page
// CID fetched and checked, then run in the sandbox loader: the board is set, a move is played by tapping two squares,
// and the engine, searching in wac-web's worker, answers. Screenshots into SHOTS.
//
//     node chess.cjs SETTINGS SUBJECT CID SHOTS
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
  const board = await frame.waitForFunction(() => document.querySelectorAll('.board .sq').length === 64, null, { timeout: 60000 })
    .then(() => true, () => false);
  ok(board, `the board is set: 64 squares (${((Date.now() - t0) / 1000).toFixed(1)} s from the click)`);
  const inside = await frame.evaluate(() => ({ origin: String(self.origin),
    api: typeof chrome !== 'undefined' && !!(chrome.runtime || chrome.storage || chrome.tabs) }));
  ok(inside.origin === 'null' && !inside.api, `it holds no extension API, and its origin is opaque (${inside.origin})`);
  await page.screenshot({ path: path.join(shots, 'admitted.png') });
  // The quickest strength, then e2-e4: the board is drawn from White's side, a8 first, so e2 is square 52 and e4 36.
  const levels = frame.locator('.controls .seg').nth(1).locator('button');
  if (await levels.count() > 0) await levels.first().click();
  await page.waitForTimeout(300);
  const sq = frame.locator('.board .sq');
  await sq.nth(52).click();
  await page.waitForTimeout(200);
  await sq.nth(36).click();
  // The moves list holds a pair to a line: White's in span.w, Black's in span.b once it is played.
  const answered = await frame.waitForFunction(() => !!document.querySelector('.moves li span.b'), null, { timeout: 60000 })
    .then(() => true, () => false);
  const moves = await frame.evaluate(() => (document.querySelector('.moves') || {}).textContent || '');
  const thinking = await frame.evaluate(() => (document.querySelector('.think-line') || {}).textContent || '');
  ok(answered && /^e4/.test(moves.trim()), `e2-e4, and the engine answers: "${moves.trim().slice(0, 40)}"; "${thinking.trim().slice(0, 80)}"`);
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(shots, 'playing.png') });
  ok(errors.length === 0, `no errors on the page${errors.length ? ': ' + errors.join('; ') : ''}`);
  await ctx.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
