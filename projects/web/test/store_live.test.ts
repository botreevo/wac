// test-lane: browser — drives Chromium through Playwright, which needs -A
// A page's store is the browser's `localStorage` for its origin (`PAGE_STORED`, `PAGE_STORE`): `example/storepage.wac`
// reads a value plain JavaScript stored before it ran, and what it stores and removes is what JavaScript then sees. It
// also names the reader's zone (`PAGE_ZONE_NAME`, set here by Playwright) and goes Back (`PAGE_BACK`) without adding to
// the history.
import { buildPage, serve, waitInPage } from "./harness.ts";

function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
}

const cannotBecause = ((): string => {
  if (Deno.permissions.querySync({ name: "sys", kind: "homedir" }).state !== "granted") return "no `sys` permission";
  const home = Deno.env.get("HOME") ?? "";
  try {
    const found = [...Deno.readDirSync(`${home}/.cache/ms-playwright`)].some((e) => e.isDirectory && e.name.startsWith("chromium"));
    return found ? "" : `no chromium in ${home}/.cache/ms-playwright`;
  } catch {
    return `no ${home}/.cache/ms-playwright`;
  }
})();
if (cannotBecause !== "") console.warn(`SKIPPING the store live test: ${cannotBecause}.`);

Deno.test({
  name: "a page reads and writes the browser's store for its origin, names its zone and goes Back",
  ignore: cannotBecause !== "",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { chromium } = await import("npm:playwright@1");
    const dir = await Deno.makeTempDir({ prefix: "web-store-" });
    let browser;
    let http: { port: number; stop(): Promise<void> } | undefined;
    try {
      await buildPage("example/storepage.wac", dir);
      const port = (http = serve(dir)).port;
      browser = await chromium.launch({ args: ["--no-proxy-server"] });
      const context = await browser.newContext({ timezoneId: "America/New_York" });
      const page = await context.newPage();
      await page.addInitScript(() => { localStorage.setItem("token", "abc"); localStorage.setItem("gone", "x"); });
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
      const lengthAtStart = await page.evaluate("history.length") as number;
      await waitInPage(page, "(() => { const e = document.getElementById('said'); return e !== null && e.textContent !== '…'; })()", null, { timeout: 30_000 });
      assertEquals(await page.evaluate("document.getElementById('said').textContent"), "abc|America/New_York|.", "read, named, and back where it started");
      assertEquals(await page.evaluate("[localStorage.getItem('seen'), localStorage.getItem('gone')]"), ["from wac", null], "stored and removed");
      assertEquals(await page.evaluate("history.length"), lengthAtStart + 1, "Back moved within the history rather than adding to it");
      assertEquals(await page.evaluate("location.hash"), "", "and the address is where it began");
    } finally {
      await browser?.close();
      await http?.stop();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
