// test-lane: browser — drives Chromium through Playwright, which needs -A
// A page talks to the server it was served from (`wac.origin`, `src/origin.wac`): `example/originpage.wac` built and
// served by a server that also answers `/echo`, `/gone` and a WebSocket at `/ws` — where the page's POST arrives with
// its fields and body, its DELETE with no body, and its socket's message is echoed, followed by two of the server's
// own and a close — and opened from a file, where there is no origin.
import { buildPage, waitInPage, findChromium } from "./harness.ts";

function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
}

// Found by `harness.ts` `findChromium`, which launches it by executable (wac `issues/system/0452e`).
const CHROMIUM = findChromium();
const cannotBecause = CHROMIUM.cannot;
if (cannotBecause !== "") console.warn(`SKIPPING the origin live test: ${cannotBecause}.`);

Deno.test({
  name: "a page asks its own origin and talks to it over a WebSocket, and has no origin from a file",
  ignore: cannotBecause !== "",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const { chromium } = await import("npm:playwright@1");
    const dir = await Deno.makeTempDir({ prefix: "web-origin-" });
    let browser;
    const heard: string[] = [];
    const server = Deno.serve({ port: 0, hostname: "127.0.0.1", onListen: () => {} }, async (req) => {
      const url = new URL(req.url);
      if (url.pathname === "/echo") {
        const body = await req.text();
        heard.push(`${req.method} ${url.pathname}${url.search} ${req.headers.get("content-type")} ${req.headers.get("authorization")} ${body}`);
        return new Response(JSON.stringify({ got: JSON.parse(body) }), { status: 201, headers: { "x-seen": "yes", "content-type": "application/json" } });
      }
      if (url.pathname === "/gone") {
        heard.push(`${req.method} ${url.pathname} ${(await req.text()).length}`);
        return new Response(null, { status: 204 });
      }
      if (url.pathname === "/ws") {
        const { socket, response } = Deno.upgradeWebSocket(req);
        socket.onmessage = (e) => {
          socket.send("echo " + e.data);
          socket.send("one");
          socket.send("two");
          socket.close(4000, "done");
        };
        return response;
      }
      try {
        const body = await Deno.readFile(`${dir}${url.pathname === "/" ? "/index.html" : url.pathname}`);
        return new Response(body, { headers: { "content-type": url.pathname.endsWith(".js") ? "text/javascript" : "text/html" } });
      } catch {
        return new Response("not found", { status: 404 });
      }
    });
    try {
      await buildPage("example/originpage.wac", dir);
      browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });
      const said = async (url: string) => {
        const page = await browser!.newPage();
        await page.goto(url, { waitUntil: "load" });
        await waitInPage(page, "(() => { const e = document.getElementById('said'); return e !== null && e.textContent !== '…'; })()", null, { timeout: 30_000 });
        return await page.evaluate("document.getElementById('said').textContent") as string;
      };
      assertEquals(await said(`http://127.0.0.1:${server.addr.port}/`),
                   '201 yes {"got":{"n":1}}|204|echo hi|one|two|closed 4000 done', "answered, and talked to");
      assertEquals(heard, ["POST /echo?q=1 application/json Bearer t {\"n\":1}", "DELETE /gone 0"], "what the server heard");
      assertEquals(await said(`file://${dir}/index.html`), "no origin: a page not served over http has no origin", "from a file");
    } finally {
      await browser?.close();
      await server.shutdown();
      await Deno.remove(dir, { recursive: true });
    }
  },
});
