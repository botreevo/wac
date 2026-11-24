// test-lane: browser — drives Chromium through Playwright, which needs -A
// A page's host answers whether the engine will load a module (`OP_VALIDATE`) by the engine's own check — not by
// whether a page could start it as a program, which wants a manifest. `wac build` asks it of every module it makes
// before writing it, so a host that asked for a manifest had every build in a desktop's Terminal called a compiler bug.
//
// **Skipped loudly** when there is no browser, in the words `packages/raster/test/live.test.ts` in wac uses.

import { buildPage, serve, waitInPage, findChromium } from "./harness.ts";
function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
}

const CHROMIUM = findChromium();
if (CHROMIUM.cannot !== "") console.warn(`SKIPPING the validate live test: ${CHROMIUM.cannot}.`);

for (const mode of [[], ["--in-page"]]) {
  Deno.test({
    name: `a module with no manifest loads, and a broken one does not${mode.length ? " — on the page's own thread" : " — in a worker"}`,
    ignore: CHROMIUM.cannot !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-validatelive-" });
      let browser;
      let http: { port: number; stop(): Promise<void> } | undefined;
      try {
        await buildPage("example/validate.wac", dir, mode);
        const port = (http = serve(dir)).port;
        browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });
        const page = await browser.newPage();
        await page.goto(`http://127.0.0.1:${port}/`);
        await waitInPage(page, "document.getElementById('said') !== null", null, { timeout: 30_000 });
        assertEquals(await page.textContent("#said"), "bare loads, broken refused");
      } finally {
        await browser?.close();
        await http?.stop();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });
}
