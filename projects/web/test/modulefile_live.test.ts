// test-lane: browser — drives Chromium through Playwright, which needs -A
// A page built with `--module-file`, in an actual browser: its module is `page.wasm` beside it, fetched by its version.
//
// What it checks is the start the module's fetch makes asynchronous: `index.html` no longer carries the module, the
// browser fetches `page.wasm?v=<version>` once, and what the document says before the program exists — whether it is
// seen, and a click on the first frame — is held for it and reaches it. The module is served slowly, so the first
// frame is on screen, and clicked, well before the program starts.
//
// **Skipped loudly** when there is no browser, in the words `packages/raster/test/live.test.ts` in wac uses.

import { buildPage, waitInPage, findChromium } from "./harness.ts";
function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) {
    throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
  }
}

const CHROMIUM = findChromium();
const cannotBecause = CHROMIUM.cannot;
if (cannotBecause !== "") {
  console.warn(
    `SKIPPING the module-file live test: ${cannotBecause}.\n` +
      `  test/wac/build_test.wac checks the page it writes without a browser; this is the one that fetches the module.`,
  );
}

for (const mode of [[], ["--in-page"]]) {
  Deno.test({
    name: `a page fetches its module from beside it, and nothing said before it arrives is lost${mode.length ? " — on the page's own thread" : " — in a worker"}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-modulefilelive-" });
      let browser;
      // A server that keeps `page.wasm` back for a while, and says what was asked of it.
      const asked: string[] = [];
      const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
        const url = new URL(req.url);
        asked.push(url.pathname + url.search);
        const path = url.pathname === "/" ? "/index.html" : url.pathname;
        try {
          const body = await Deno.readFile(`${dir}${path}`);
          if (path.endsWith(".wasm")) await new Promise((r) => setTimeout(r, 1500));
          return new Response(body, { headers: { "content-type": path.endsWith(".wasm") ? "application/wasm" : "text/html" } });
        } catch {
          return new Response("not found", { status: 404 });
        }
      });
      try {
        await buildPage("example/todofirst.wac", dir, [...mode, "--module-file"]);
        const index = await Deno.readTextFile(`${dir}/index.html`);
        assertEquals(index.includes('id="wac-module"'), false, "index.html does not carry the module");
        const version = index.match(/page\.wasm\?v=([0-9a-f]{8})/)?.[1] ?? "";
        assertEquals(version.length, 8, "index.html names the module by its version");

        browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });
        const page = await browser.newPage();
        const failures: string[] = [];
        page.on("pageerror", (e: Error) => failures.push(String(e)));
        page.on("console", (m: { type(): string; text(): string }) => { if (m.type() === "error") failures.push(m.text()); });
        await page.goto(`http://127.0.0.1:${server.addr.port}/`, { waitUntil: "domcontentloaded" });
        // While the module is held back: the first frame is there, and a reader types and clicks add.
        await page.waitForSelector("#add");
        assertEquals(await page.evaluate("document.getElementById('app').hasAttribute('data-wac-pre')"), true,
                     "the program has not started");
        await page.fill("#what", "milk");
        await page.click("#add");
        await waitInPage(page, "document.getElementById('count').textContent === '1 to do'", null, { timeout: 30_000 });
        assertEquals(await page.textContent("#items"), "milk", "the click made before the module arrived reached the program");
        assertEquals(asked.filter((a) => a.startsWith("/page.wasm")), [`/page.wasm?v=${version}`], "the module was fetched once, by its version");
        // And the program heard the document's first word — that it is seen — though it was said before it started.
        assertEquals(await page.evaluate("document.visibilityState"), "visible");
        await page.fill("#what", "eggs");
        await page.press("#what", "Enter");
        await waitInPage(page, "document.getElementById('count').textContent === '2 to do'", null, { timeout: 10_000 });
        assertEquals(failures, [], "the page reported an error");
      } finally {
        await browser?.close();
        await server.shutdown();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });
}
