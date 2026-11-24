// Chromium, running `@kpstreams/webrtc-client` unmodified, dials a KPS listener — the browser leg of SPEC §10.
//
//   node browser-dial.mjs <address>
//
// Serves page/index.html with an import map onto the npm packages' dist trees (no bundler, as the kps repo's own
// interop page does), opens it in Chromium, and prints what `window.runAll` reports, then `DONE <n>`.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = dirname(fileURLToPath(import.meta.url));
const routes = {
  "/kps/core/": join(here, "node_modules/@kpstreams/core/dist/"),
  "/kps/webrtc-client/": join(here, "node_modules/@kpstreams/webrtc-client/dist/"),
};
const mime = { ".html": "text/html", ".js": "application/javascript", ".map": "application/json" };
const server = createServer(async (req, res) => {
  let file = join(here, "page", "index.html");
  for (const [prefix, dir] of Object.entries(routes)) {
    if (req.url.startsWith(prefix)) file = join(dir, req.url.slice(prefix.length));
  }
  try {
    res.writeHead(200, { "content-type": mime[extname(file)] ?? "application/octet-stream" });
    res.end(await readFile(file));
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || undefined,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--allow-loopback-in-peer-connection"],
});
let results = [];
try {
  const context = await browser.newContext({ permissions: ["microphone"] });
  const page = await context.newPage();
  page.on("pageerror", (e) => console.error("[page error]", e.message));
  await page.goto(url);
  await page.waitForFunction(() => document.getElementById("status").textContent === "ready");
  results = process.argv[3] === "timed"
    ? await page.evaluate((addr) => window.runTimed(addr, [16384, 65536, 262144, 1048576]), process.argv[2])
    : await page.evaluate((addr) => window.runAll(addr), process.argv[2]);
} catch (e) {
  results.push(`FAIL the browser ran: ${e.message}`);
} finally {
  await browser.close();
  server.close();
}
for (const r of results) console.log(r);
console.log(`DONE ${results.length}`);
