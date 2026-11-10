// test-lane: browser
//
// `--layout files` under the CSP a Manifest V3 extension page gets — no inline script, no `blob:` worker,
// `'wasm-unsafe-eval'` for the module — in Chromium: `example/hostget.wac` takes its argument from `args.json`, reaches a
// same-origin URL through `wac.http`, and exits 0 with nothing refused. The single-page layout under the same policy
// is refused at its inline launcher, which is the control: the policy is strict enough to tell the two apart.
//
// Skipped where Chromium is not installed, as the other live tests are (see `issues/system/0452e`).
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
if (cannotBecause !== "") console.error(`csp_live: skipped — ${cannotBecause}`);

/** A Manifest V3 extension page's default policy, plus the inline style the page itself uses. */
const CSP = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'; " +
  "object-src 'self'; style-src 'self' 'unsafe-inline'";

function serve(dir: string): { port: number; stop(): Promise<void> } {
  const server = Deno.serve({ port: 0, onListen: () => {} }, async (req) => {
    const path = new URL(req.url).pathname;
    const h = {
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
      "content-security-policy": CSP,
    };
    if (path === "/small") return new Response("hello", { headers: { "x-probe": "seen", ...h } });
    const name = path.replace(/^\/+/, "") || "index.html";
    const type = name.endsWith(".html") ? "text/html" : name.endsWith(".js") ? "text/javascript"
      : name.endsWith(".json") ? "application/json" : "application/wasm";
    try {
      return new Response(await Deno.readFile(`${dir}/${name}`), { headers: { "content-type": type, ...h } });
    } catch {
      return new Response("no", { status: 404, headers: h });
    }
  });
  return { port: (server.addr as Deno.NetAddr).port, stop: () => server.shutdown() };
}

/** Load `dir`'s page under the policy; its text when it exits, and every message the policy logged. */
async function runUnder(dir: string): Promise<{ text: string; refused: string[] }> {
  const { chromium } = await import("npm:playwright@1");
  const http = serve(dir);
  const browser = await chromium.launch({ args: ["--no-proxy-server"] });
  try {
    await Deno.writeTextFile(`${dir}/args.json`, JSON.stringify([`http://127.0.0.1:${http.port}/small`]));
    const tab = await browser.newPage();
    const refused: string[] = [];
    tab.on("console", (m: { text(): string }) => {
      if (/Content Security Policy|Refused to/.test(m.text())) refused.push(m.text());
    });
    await tab.goto(`http://127.0.0.1:${http.port}/index.html`);
    try {
      await waitInPage(tab, "document.body.innerText.includes('[exit')", { timeout: 20_000 });
    } catch { /* the control never exits; what it logged says why */ }
    return { text: await tab.evaluate("document.body.innerText") as string, refused };
  } finally {
    await browser.close();
    await http.stop();
  }
}

Deno.test({
  name: "--layout files runs under an extension's CSP, and the single page does not",
  ignore: cannotBecause !== "",
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const dir = await Deno.makeTempDir({ prefix: "wac-csp-" });
    try {
      await buildApp("packages/platform/example/hostget.wac", `${dir}/files`, { net: true }, "browser", false, { layout: "files" });
      const split = await runUnder(`${dir}/files`);
      assertEquals(split.refused.length, 0, `the policy refused: ${split.refused.join("\n")}`);
      assertEquals(split.text.includes("status 200 length 5 header seen"), true, split.text);
      assertEquals(split.text.includes("[exit 0]"), true, split.text);

      await Deno.mkdir(`${dir}/page`);
      await buildApp("packages/platform/example/hostget.wac", `${dir}/page/index.html`, { net: true }, "browser");
      const whole = await runUnder(`${dir}/page`);
      assertEquals(whole.refused.some((r) => r.includes("inline script")), true, `the control ran: ${whole.text}`);
    } finally {
      await Deno.remove(dir, { recursive: true });
    }
  },
});
