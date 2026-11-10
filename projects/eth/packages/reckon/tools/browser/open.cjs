// Open URL in headless Chromium (Playwright's, preinstalled) and print the page's text once it ends: when it shows
// "[exit N]", or has stopped changing for 3 s, or after TIMEOUT ms. Console errors go to stderr. With THEN URL2…, the
// later URLs are opened in turn in the same browser, so what the first left in the browser's storage is there for
// the next; each page's text is printed after a line `== page N`.
//
//     node open.cjs URL [TIMEOUT] [THEN URL2 …]
const { chromium } = require('playwright');
(async () => {
  const [url, timeout] = [process.argv[2], Number(process.argv[3] || 120000)];
  const urls = [url, ...process.argv.slice(4).filter((a) => a !== 'THEN')];
  const browser = await chromium.launch();
  const context = await browser.newContext();
  for (let n = 0; n < urls.length; n++) {
    const page = await context.newPage();
    page.on('console', (m) => { if (m.type() === 'error') console.error('console:', m.text()); });
    page.on('pageerror', (e) => console.error('pageerror:', e.message));
    await page.goto(urls[n]);
    let last = '', same = 0; const t0 = Date.now();
    while (Date.now() - t0 < timeout) {
      await page.waitForTimeout(500);
      const now = await page.evaluate(() => document.body.innerText);
      if (/\[exit -?\d+\]/.test(now)) { last = now; break; }
      if (now === last && now.length > 0) { if (++same >= 6) break; } else { same = 0; last = now; }
    }
    if (urls.length > 1) console.log(`== page ${n + 1}`);
    console.log(last);
    await page.close();
  }
  await browser.close();
})();
