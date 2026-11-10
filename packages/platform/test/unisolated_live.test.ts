// **A `main(Sys)` page in a frame that cannot be isolated** — `packages/platform/host/asynchost.ts`.
//
// wac-eth's reckon loads apps in an opaque-origin sandbox frame, which is never cross-origin isolated, so it has no
// `SharedArrayBuffer` and the blocking host cannot start; `allow="cross-origin-isolated"` and `credentialless` do not
// change that. An `async` main does not need to block, and runs there on the async host. One that is not `async` is
// refused, saying both ways out, rather than failing at its first wait.
//
// Run with `deno test -A --unstable-net packages/platform/test/unisolated_live.test.ts`; skipped, saying why, where
// there is no Chromium (`harness/chromium.ts`).

import { buildApp } from "../build.ts";
import { findChromium, launchOptions } from "../../../harness/chromium.ts";
import { waitInPage } from "../../../harness/buildPage.ts";

const CHROMIUM = findChromium();
if (CHROMIUM.cannot !== "") console.error(`unisolated_live: skipped — ${CHROMIUM.cannot}`);

function assertEquals<T>(a: T, b: T, msg?: string): void {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${JSON.stringify(a)}\n  want: ${JSON.stringify(b)}`);
  }
}

/**
 * Pages with **no isolation headers**, and `frame.html`, which loads `?page=<name>` in a `sandbox="allow-scripts"`
 * frame — an opaque origin, as reckon's app loader is.
 */
function serve(dir: string): { port: number; stop(): Promise<void> } {
  const server = Deno.serve({ port: 0, onListen: () => {} }, async (req) => {
    const url = new URL(req.url);
    const name = url.pathname.replace(/^\/+/, "");
    if (name === "frame.html") {
      const page = url.searchParams.get("page") ?? "";
      return new Response(`<!doctype html><iframe id="app" sandbox="allow-scripts" src="/${page}?a=one"></iframe>`,
        { headers: { "content-type": "text/html; charset=utf-8" } });
    }
    try {
      return new Response(await Deno.readFile(`${dir}/${name}`), { headers: { "content-type": "text/html; charset=utf-8" } });
    } catch {
      return new Response("no", { status: 404 });
    }
  });
  return { port: (server.addr as Deno.NetAddr).port, stop: () => server.shutdown() };
}

Deno.test({
  name: "an async main(Sys) runs in a frame with no SharedArrayBuffer, and a sync one is refused saying why",
  ignore: CHROMIUM.cannot !== "",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { chromium } = await import("npm:playwright@1");
    const dir = await Deno.makeTempDir({ prefix: "wac-unisolated-" });
    let browser;
    let http: { port: number; stop(): Promise<void> } | undefined;
    try {
      await buildApp("packages/platform/example/unwaiting.wac", `${dir}/unwaiting.html`, {}, "browser");
      await buildApp("packages/platform/example/clocks.wac", `${dir}/hello.html`, {}, "browser");
      const port = (http = serve(dir)).port;
      browser = await chromium.launch(launchOptions(CHROMIUM));
      const page = await browser.newPage();

      for (const [where, url] of [
        ["no isolation headers", `http://127.0.0.1:${port}/unwaiting.html?a=one`],
        ["an opaque sandbox frame", `http://127.0.0.1:${port}/frame.html?page=unwaiting.html`],
      ]) {
        await page.goto(url, { waitUntil: "load" });
        const frame = where.startsWith("an opaque") ? page.frames()[1] : page.mainFrame();
        assertEquals(await frame.evaluate("globalThis.crossOriginIsolated === true"), false, `${where}: not isolated`);
        await waitInPage(frame, "(document.getElementById('out')?.textContent ?? '').includes('[exit')", null,
          { timeout: 30_000 });
        assertEquals(
          await frame.evaluate("document.getElementById('out').textContent"),
          "args: 1 one\nwaited without blocking\n[exit 3]\n",
          where,
        );
      }

      await page.goto(`http://127.0.0.1:${port}/frame.html?page=hello.html`, { waitUntil: "load" });
      const frame = page.frames()[1];
      await waitInPage(frame, "(document.getElementById('out')?.textContent ?? '') !== ''", null, { timeout: 30_000 });
      const said = await frame.evaluate("document.getElementById('out').textContent") as string;
      if (!said.includes("only an `async` main runs without waiting")) throw new Error(`a sync main, unisolated: ${said}`);
    } finally {
      await browser?.close();
      await http?.stop();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
