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
  const hung: ReturnType<typeof setTimeout>[] = [];
  const server = Deno.serve({ port: 0, onListen: () => {} }, async (req) => {
    const url = new URL(req.url);
    const name = url.pathname.replace(/^\/+/, "");
    if (name === "frame.html") {
      const page = url.searchParams.get("page") ?? "";
      const query = url.searchParams.get("q") ?? "a=one";
      return new Response(`<!doctype html><iframe id="app" sandbox="allow-scripts" src="/${page}?${query}"></iframe>`,
        { headers: { "content-type": "text/html; charset=utf-8" } });
    }
    // For `wac.http` from the frame, whose origin is opaque: a cross-origin request, so the answer says it may be read.
    const cors = { "access-control-allow-origin": "*" };
    if (name === "ok") return new Response("hello", { headers: cors });
    if (name === "hang") {
      // Longer than any deadline here, and short enough to let the server stop.
      await new Promise((r) => hung.push(setTimeout(r, 3000)));
      return new Response("late", { headers: cors });
    }
    const type = name.endsWith(".js") ? "text/javascript" : name.endsWith(".wasm") ? "application/wasm"
      : name.endsWith(".json") ? "application/json" : "text/html; charset=utf-8";
    try {
      return new Response(await Deno.readFile(`${dir}/${name}`), { headers: { "content-type": type, ...cors } });
    } catch {
      return new Response("no", { status: 404 });
    }
  });
  return {
    port: (server.addr as Deno.NetAddr).port,
    stop: async () => { for (const h of hung) clearTimeout(h); await server.shutdown(); },
  };
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

      // **`wac.http` with a deadline** (`issues/system/0461e`): answered, timed out at its deadline, and a blocking
      // request refused rather than left waiting for ever.
      await buildApp("packages/platform/example/unwaitingget.wac", `${dir}/get.html`, { net: true }, "browser");
      const q = encodeURIComponent(`a=${encodeURIComponent(`http://127.0.0.1:${port}/ok`)}` +
        `&a=${encodeURIComponent(`http://127.0.0.1:${port}/hang`)}`);
      await page.goto(`http://127.0.0.1:${port}/frame.html?page=get.html&q=${q}`, { waitUntil: "load" });
      const getFrame = page.frames()[1];
      await waitInPage(getFrame, "(document.getElementById('out')?.textContent ?? '').includes('[exit')", null,
        { timeout: 30_000 });
      const got = (await getFrame.evaluate("document.getElementById('out').textContent") as string).split("\n");
      assertEquals(got[0], "status 200 hello", "wac.http, answered");
      assertEquals(got[1], `err 127.0.0.1: timed out after 500ms`, "wac.http, past its deadline");
      if (!got[2].startsWith("sync err ")) throw new Error(`a blocking request on a host that cannot wait: ${got[2]}`);
      assertEquals(got[3], "[exit 0]", "and the program finished");

      // **`--layout files` in the same frame**: the page loads its worker by URL rather than from its own source.
      await buildApp("packages/platform/example/unwaiting.wac", `${dir}/files`, {}, "browser", false, { layout: "files" });
      await page.goto(`http://127.0.0.1:${port}/frame.html?page=files/index.html`, { waitUntil: "load" });
      const filesFrame = page.frames()[1];
      await waitInPage(filesFrame, "(document.getElementById('out')?.textContent ?? '').includes('[exit')", null,
        { timeout: 30_000 }).catch(async (e: Error) => {
          throw new Error(`${e.message}\n--layout files in an opaque frame shows: ` +
            JSON.stringify(await filesFrame.evaluate("document.getElementById('out')?.textContent ?? document.body.innerHTML")));
        });
      assertEquals(
        await filesFrame.evaluate("document.getElementById('out').textContent"),
        "args: 1 one\nwaited without blocking\n[exit 3]\n",
        "--layout files in an opaque frame",
      );
    } finally {
      await browser?.close();
      await http?.stop();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
