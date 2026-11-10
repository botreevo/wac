// Open URL in headless Chromium (Playwright's, preinstalled) and print the page's text once it ends: when it shows
// "[exit N]", or has stopped changing for 3 s, or after TIMEOUT ms. Console errors go to stderr.
//
//     node open.cjs URL [TIMEOUT]
const { chromium } = require('playwright');
(async () => {
  const [url, timeout] = [process.argv[2], Number(process.argv[3] || 120000)];
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('console', (m) => { if (m.type() === 'error') console.error('console:', m.text()); });
  page.on('pageerror', (e) => console.error('pageerror:', e.message));
  await page.goto(url);
  let last = '', same = 0; const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    await page.waitForTimeout(500);
    const now = await page.evaluate(() => document.body.innerText);
    if (/\[exit -?\d+\]/.test(now)) { last = now; break; }
    if (now === last && now.length > 0) { if (++same >= 6) break; } else { same = 0; last = now; }
  }
  console.log(last);
  await browser.close();
})();
