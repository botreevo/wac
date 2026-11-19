// test-lane: browser — drives Chromium through Playwright, which needs -A
// A site of routes, in an actual browser: `example/routes.wac`, three pages drawn at build time, each its own
// `index.html`, served from a folder of a host — `/site/` — as a site often is.
//
// What it checks: each page is there before any script, with its own title and description; the program, told its path
// before its first turn, adopts the frame; a link between pages is followed in the page — the address changes, the
// module is not fetched again, the title and description follow — and Back returns; a link clicked before the module
// has arrived loads the page it names, which is there, drawn; and the sitemap names every page.
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
    `SKIPPING the routes live test: ${cannotBecause}.\n` +
      `  test/wac/build_test.wac checks the pages the build writes without a browser; this is the one that follows links.`,
  );
}

const hydrated = "!document.getElementById('app').hasAttribute('data-wac-pre')";

for (const mode of [[], ["--in-page"]]) {
  Deno.test({
    name: `a site of routes: each page drawn, a link followed in the page, Back${mode.length ? " — on the page's own thread" : " — in a worker"}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-routeslive-" });
      let browser;
      // The site served from `/site/`, its module held back as long as `slow` says.
      const asked: string[] = [];
      let slow = 0;
      const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
        const url = new URL(req.url);
        asked.push(url.pathname);
        if (!url.pathname.startsWith("/site/")) return new Response("not found", { status: 404 });
        let path = url.pathname.slice("/site".length);
        if (path.endsWith("/")) path += "index.html";
        try {
          const body = await Deno.readFile(`${dir}${path}`);
          const wasm = path.endsWith(".wasm");
          if (wasm && slow > 0) await new Promise((r) => setTimeout(r, slow));
          const type = wasm ? "application/wasm" : path.endsWith(".xml") ? "application/xml" : "text/html";
          return new Response(body, { headers: { "content-type": type } });
        } catch {
          return new Response("not found", { status: 404 });
        }
      });
      const site = `http://127.0.0.1:${server.addr.port}/site/`;
      try {
        await buildPage("example/routes.wac", dir, [...mode, "--module-file", "--site-url", "https://example.org/site"]);

        // Before any script: each page is itself.
        const still = await (await browser_(chromium)).newContext({ javaScriptEnabled: false });
        const s = await still.newPage();
        await s.goto(`${site}docs/a/`);
        assertEquals(await s.title(), "Page A", "the page at /docs/a/ is titled for it");
        assertEquals(await s.textContent("#title"), "Page A", "and drawn");
        assertEquals(await s.getAttribute('meta[name="description"]', "content"), "Page A: All about A.", "and described");
        assertEquals(await s.getAttribute('link[rel="canonical"]', "href"), "https://example.org/site/docs/a/", "with its address");
        assertEquals(await s.getAttribute("#to-2", "href"), "../b/", "its links are relative");
        await s.click("#to-2");
        assertEquals(await s.textContent("#title"), "Page B", "and followed with no script at all, to a page that is there");

        // With script: the frame adopted, then a link followed in the page.
        const page = await (await browser_(chromium)).newPage();
        const said: string[] = [];
        const failures: string[] = [];
        page.on("console", (m: { type(): string; text(): string }) => { said.push(m.text()); if (m.type() === "error") failures.push(m.text()); });
        page.on("pageerror", (e: Error) => failures.push(String(e)));
        await page.goto(`${site}docs/a/`);
        await waitInPage(page, hydrated, null, { timeout: 30_000 });
        assertEquals(said.filter((l) => l.startsWith("wac: hydrated")), [], "the program drew /docs/a/ as the build did");
        await page.evaluate("window.__stayed = true");
        await page.click("#to-2");
        await waitInPage(page, "document.getElementById('title').textContent === 'Page B'", null, { timeout: 10_000 });
        assertEquals(new URL(page.url()).pathname, "/site/docs/b/", "the address is the page's");
        assertEquals(await page.evaluate("window.__stayed === true"), true, "the page was not loaded again");
        await waitInPage(page, "document.title === 'Page B'", null, { timeout: 5_000 });
        assertEquals(await page.getAttribute('meta[name="description"]', "content"), "Page B: All about B.", "the description followed");
        assertEquals(await page.getAttribute("#to-1", "href"), "../a/", "and the links are relative to the new page");
        await page.goBack();
        await waitInPage(page, "document.getElementById('title').textContent === 'Page A'", null, { timeout: 10_000 });
        assertEquals(new URL(page.url()).pathname, "/site/docs/a/", "Back");
        await page.click("#to-0");
        await waitInPage(page, "document.getElementById('title').textContent === 'Home'", null, { timeout: 10_000 });
        assertEquals(new URL(page.url()).pathname, "/site/", "the site's root");
        assertEquals(asked.filter((a) => a.endsWith("page.wasm")).length, 1, "the module was fetched once for every page");
        assertEquals(failures, [], "the page reported an error");

        // A link clicked before the module has arrived loads the page it names: that page is there, drawn.
        slow = 3000;
        const early = await (await browser_(chromium)).newPage();
        await early.goto(`${site}docs/a/`, { waitUntil: "domcontentloaded" });
        await early.click("#to-2");
        await early.waitForURL(`${site}docs/b/`);
        assertEquals(await early.textContent("#title"), "Page B", "an early click loads the page");
        slow = 0;

        const sitemap = await (await fetch(`${site}sitemap.xml`)).text();
        for (const p of ["", "docs/a/", "docs/b/"]) {
          assertEquals(sitemap.includes(`<loc>https://example.org/site/${p}</loc>`), true, `the sitemap names /${p}`);
        }
      } finally {
        await browser?.close();
        await server.shutdown();
        await Deno.remove(dir, { recursive: true });
      }

      // One browser for the test, launched when first asked for.
      async function browser_(c: { launch(o: unknown): Promise<unknown> }) {
        // deno-lint-ignore no-explicit-any
        browser ??= await c.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] }) as any;
        return browser;
      }
    },
  });
}
