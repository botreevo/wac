// test-lane: browser — drives Chromium through Playwright, which needs -A
// A page puts a scroller where it wants it (`Element.prop("scrollTop", …)`) and hears where it went (a `scroll`
// event's value): `example/scrollpage.wac` scrolls its list to 120 once drawn, and shows each scroll's position.
import { buildPage, serve, waitInPage, findChromium } from "./harness.ts";

function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
}

// Found by `harness.ts` `findChromium`, which launches it by executable (wac `issues/system/0452e`).
const CHROMIUM = findChromium();
const cannotBecause = CHROMIUM.cannot;
if (cannotBecause !== "") console.warn(`SKIPPING the scroll live test: ${cannotBecause}.`);

Deno.test({
  name: "a page sets where a scroller is, and hears where it scrolls to",
  ignore: cannotBecause !== "",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { chromium } = await import("npm:playwright@1");
    const dir = await Deno.makeTempDir({ prefix: "web-scroll-" });
    let browser;
    let http: { port: number; stop(): Promise<void> } | undefined;
    try {
      await buildPage("example/scrollpage.wac", dir);
      const port = (http = serve(dir)).port;
      browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });
      const page = await browser.newPage();
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
      await waitInPage(page, "(() => { const e = document.getElementById('said'); return e !== null && e.textContent === '120'; })()", null, { timeout: 30_000 });
      assertEquals(await page.evaluate("document.getElementById('list').scrollTop"), 120, "put where the page wanted it");
      await page.evaluate("document.getElementById('list').scrollTop = 333");
      await waitInPage(page, "(() => document.getElementById('said').textContent === '333')()", null, { timeout: 10_000 });
    } finally {
      await browser?.close();
      await http?.stop();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
