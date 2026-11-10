// test-lane: browser
//
// `wac.http` in a real page: `example/hostget.wac`, built `--target browser --allow-net`, asks `packages/http`'s client
// for three URLs and the client — finding no sockets and the page's `fetch` offered by name — gets them by
// `wac.http`. A response with a header, one whose body is several of the bridge's chunks, and one from another
// origin that sends no CORS headers, which the browser refuses and the program is told so in exactly those words.
//
// Skipped where Chromium is not installed, as `browser_live.test.ts` is.
import { buildApp } from "../build.ts";
import { waitInPage } from "../../../harness/buildPage.ts";
import "../../../harness/spawnRetry.ts";

function assertEquals<T>(got: T, want: T, msg?: string): void {
  if (got !== want) throw new Error(`${msg ?? "assertEquals"}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
}

function canDriveBrowser(): string {
  if (Deno.permissions.querySync({ name: "sys", kind: "homedir" }).state !== "granted") {
    return "no `sys` permission: run this file with `deno test -A`";
  }
  const home = Deno.env.get("HOME");
  if (home === undefined) return "no HOME to look for a browser under";
  try {
    const found = [...Deno.readDirSync(`${home}/.cache/ms-playwright`)]
      .some((e) => e.isDirectory && e.name.startsWith("chromium"));
    if (!found) return `no chromium in ${home}/.cache/ms-playwright`;
  } catch {
    return `no ${home}/.cache/ms-playwright: no browser installed`;
  }
  return "";
}
const cannotBecause = canDriveBrowser();
if (cannotBecause !== "") console.error(`hostget_live: skipped — ${cannotBecause}`);

/** 200 KB, three of the bridge's 64 KiB chunks and a part: what a body streamed through `read` looks like. */
const BIG = "0123456789".repeat(20_000);

/** The page, and the API beside it on the same origin — which a page under COEP may fetch without CORS. */
function servePage(dir: string): { port: number; stop(): Promise<void> } {
  const server = Deno.serve({ port: 0, onListen: () => {} }, async (req) => {
    const path = new URL(req.url).pathname;
    const isolated = { "cross-origin-opener-policy": "same-origin", "cross-origin-embedder-policy": "require-corp" };
    if (path === "/small") return new Response("hello", { headers: { "x-probe": "seen", ...isolated } });
    if (path === "/big") return new Response(BIG, { headers: isolated });
    try {
      const body = await Deno.readFile(`${dir}/${path.replace(/^\/+/, "") || "index.html"}`);
      return new Response(body, { headers: { "content-type": "text/html; charset=utf-8", ...isolated } });
    } catch {
      return new Response("no", { status: 404 });
    }
  });
  return { port: (server.addr as Deno.NetAddr).port, stop: () => server.shutdown() };
}

/** Another origin, which answers but sends no `Access-Control-Allow-Origin`: the browser will not hand it over. */
function serveElsewhere(): { port: number; stop(): Promise<void> } {
  const server = Deno.serve({ port: 0, onListen: () => {} }, () => new Response("secret"));
  return { port: (server.addr as Deno.NetAddr).port, stop: () => server.shutdown() };
}

Deno.test({
  name: "a page's program reaches HTTP through wac.http, with its body streamed and a CORS refusal named",
  ignore: cannotBecause !== "",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { chromium } = await import("npm:playwright@1");
    const dir = await Deno.makeTempDir({ prefix: "wac-hostget-" });
    const page = servePage(dir);
    const elsewhere = serveElsewhere();
    let browser;
    try {
      await buildApp("packages/platform/example/hostget.wac", `${dir}/index.html`, { net: true }, "browser");
      browser = await chromium.launch({ args: ["--no-proxy-server"] });
      const tab = await browser.newPage();
      const at = (port: number, path: string) => `http://127.0.0.1:${port}${path}`;
      const urls = [at(page.port, "/small"), at(page.port, "/big"), at(elsewhere.port, "/")];
      await tab.goto(`${at(page.port, "/index.html")}?${urls.map((u) => `a=${encodeURIComponent(u)}`).join("&")}`);
      await waitInPage(tab, "document.body.innerText.includes('[exit')", { timeout: 60_000 });
      const text: string = await tab.evaluate("document.body.innerText");
      const lines = text.split("\n").filter((l) => l.startsWith("status ") || l.startsWith("err "));
      assertEquals(lines[0], "status 200 length 5 header seen", text);
      assertEquals(lines[1], `status 200 length ${BIG.length} header -`, text);
      assertEquals(lines[2], `err 127.0.0.1: network error or CORS refusal`, text);
      assertEquals(text.includes("[exit 0]"), true, text);
    } finally {
      await browser?.close();
      await page.stop();
      await elsewhere.stop();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
