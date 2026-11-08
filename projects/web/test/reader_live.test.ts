// test-lane: browser — drives Chromium through Playwright, which needs -A
// What a page knows of its reader, in an actual browser: `example/reader.wac` built as a page and opened by Chromium
// in New York's time zone, then hidden and shown again.
//
// `test/wac/page_test.wac` checks `zoneAt` and `visible` against `TestDoc`, whose answers are the test's own. What it
// cannot check is the browser's host: that the zone comes from the reader's clock — the worker's `Date`, in a worker
// — that hiding the page reaches the program and showing it again does too, and that an `svg` and what is made in
// it are made in SVG's namespace, where they draw, rather than as unknown HTML elements, where they do not.
//
// **Skipped loudly** when there is no browser, in the words `packages/raster/test/live.test.ts` in wac uses.

import { buildPage, serve, waitInPage } from "./harness.ts";
function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) {
    throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
  }
}

const cannotBecause = ((): string => {
  if (Deno.permissions.querySync({ name: "sys", kind: "homedir" }).state !== "granted") {
    return "no `sys` permission: run this file with `deno test -A`";
  }
  const home = Deno.env.get("HOME") ?? "";
  try {
    const found = [...Deno.readDirSync(`${home}/.cache/ms-playwright`)]
      .some((e) => e.isDirectory && e.name.startsWith("chromium"));
    if (!found) return `no chromium in ${home}/.cache/ms-playwright`;
  } catch {
    return `no ${home}/.cache/ms-playwright — run: ./node_modules/.bin/playwright install chromium`;
  }
  return "";
})();
if (cannotBecause !== "") {
  console.warn(
    `SKIPPING the reader live test: ${cannotBecause}.\n` +
      `  test/wac/page_test.wac checks the zone and visibility without a browser; this is the one that reaches a real document.`,
  );
}

for (const mode of [[], ["--in-page"]]) {
  Deno.test({
    name: `a page knows its reader's zone, whether it is seen, and draws SVG${mode.length ? " — on the page's own thread" : " — in a worker"}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-readerlive-" });
      let browser;
      let http: { port: number; stop(): Promise<void> } | undefined;
      try {
        await buildPage("example/reader.wac", dir, mode);
        const port = (http = serve(dir)).port;
        browser = await chromium.launch({ args: ["--no-proxy-server"] });
        const context = await browser.newContext({ timezoneId: "America/New_York" });
        const page = await context.newPage();
        const failures: string[] = [];
        page.on("pageerror", (e: Error) => failures.push(String(e)));
        page.on("console", (m: { type(): string; text(): string }) => { if (m.type() === "error") failures.push(m.text()); });
        await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
        const text = async (id: string): Promise<string> =>
          await page.evaluate(`(() => { const e = document.getElementById(${JSON.stringify(id)}); return e ? e.textContent : null; })()`) as string;
        await waitInPage(page, "document.getElementById('zone') !== null", null, { timeout: 30_000 });

        // New York is five hours behind UTC in winter and four in summer; the page's own `Date` says which applies now.
        const want = await page.evaluate("-new Date().getTimezoneOffset()") as number;
        assertEquals([-300, -240].includes(want), true, "the browser is in New York's zone");
        assertEquals(await text("zone"), String(want), "the zone the program was told");

        assertEquals(await text("seen"), "seen", "a page opened in front of the reader is seen");
        // Hidden as a browser hides a tab in the background: the state changes, then the event says so.
        await page.evaluate(`(() => {
          Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
          document.dispatchEvent(new Event("visibilitychange"));
        })()`);
        await waitInPage(page, "document.getElementById('seen').textContent === 'away'", null, { timeout: 10_000 });
        assertEquals(await text("away"), "1", "heard going out of sight once");
        await page.evaluate(`(() => {
          Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
          document.dispatchEvent(new Event("visibilitychange"));
        })()`);
        await waitInPage(page, "document.getElementById('seen').textContent === 'seen'", null, { timeout: 10_000 });

        const drawn = await page.evaluate(`(() => {
          const svg = document.getElementById("drawing"), line = svg.querySelector("line"), t = svg.querySelector("text");
          const NS = "http://www.w3.org/2000/svg";
          return { ns: [svg.namespaceURI === NS, line.namespaceURI === NS, t.namespaceURI === NS],
                   wide: Math.round(line.getBoundingClientRect().width) };
        })()`) as { ns: boolean[]; wide: number };
        assertEquals(drawn.ns, [true, true, true], "the svg, its line and its text are SVG elements");
        assertEquals(drawn.wide, 96, "the line is drawn, 80% of 120 pixels wide");
        assertEquals(failures, [], "the page reported an error");
      } finally {
        await browser?.close();
        await http?.stop();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });
}
