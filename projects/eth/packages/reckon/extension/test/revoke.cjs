// The extension with SETTINGS (revoke.sh): APP admitted as of a block, REVOKE run (the endorsement revoked on chain),
// then APP opened again and refused, the revocation proved, as of a later block.
//
//     node revoke.cjs SETTINGS APP REVOKE
const { chromium } = require('playwright');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const [settingsFile, appCid, revoke] = process.argv.slice(2);
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
  await page.goto(`chrome-extension://${id}/page.html`);
  await page.evaluate((s) => chrome.storage.local.set({ settings: s }), settings);
  await page.reload();
  const open = async (subject) => {
    await page.fill('#subject', subject);
    await page.click('#open button');
    await page.waitForFunction(() => /^(ADMITTED|REFUSED)$/m.test(document.getElementById('account').textContent), null, { timeout: 180000 });
    await page.waitForTimeout(1000);
    return page.evaluate(() => ({ account: document.getElementById('account').textContent, asof: document.getElementById('asof').textContent,
      fresh: document.getElementById('asof').className, shown: document.getElementById('app').classList.contains('shown') }));
  };
  const block = (s) => { const m = /execution block (\d+)/.exec(s); return m ? Number(m[1]) : -1; };

  const a = await open(appCid);
  console.log('   | ' + a.account.split('\n').filter((l) => /^chain:|^as of|ADMITTED|REFUSED/.test(l)).join('\n   | '));
  console.log('   | banner: ' + a.asof);
  ok(/^ADMITTED$/m.test(a.account) && /0 revocation\(s\)/.test(a.account) && a.shown, 'admitted and shown: the registry read by proof, no revocation set');
  ok(/^Admitted as of execution block \d+/.test(a.asof) && a.fresh === 'fresh', `the page says what it is as of, and that it is fresh: "${a.asof.slice(0, 60)}…"`);
  execSync(revoke, { stdio: 'ignore' });
  const b = await open(appCid);
  console.log('   | ' + b.account.split('\n').filter((l) => /^chain:|^as of|endorsed|ADMITTED|REFUSED/.test(l)).join('\n   | '));
  console.log('   | banner: ' + b.asof);
  ok(/^REFUSED$/m.test(b.account) && /1 revocation\(s\)/.test(b.account) && /endorsed by nobody/.test(b.account),
     'after the endorser revokes on chain, the next open proves the revocation and refuses');
  ok(!b.shown, '…and the app is no longer shown');
  ok(block(b.asof) > block(a.asof), `…as of a later block (${block(a.asof)} → ${block(b.asof)})`);
  await ctx.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
