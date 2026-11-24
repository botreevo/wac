// A built wac page that dials a KPS listener (wac-kps's cmd/dialpage.wac), driven in Chromium.
//
//   node page-dial.mjs <page-dir> <address>
//
// Serves the page, grants it media (Chromium shows a page no local interface to gather ICE candidates on without it,
// and a wac page cannot ask), sets the address as its `#` part, and prints what the page reports, ending `DONE <n>`.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname } from "node:path";
import { chromium } from "playwright";

const [dir, address] = process.argv.slice(2);
const mime = { ".html": "text/html", ".wasm": "application/wasm", ".js": "application/javascript" };
const server = createServer(async (req, res) => {
  const path = req.url.split("?")[0].split("#")[0];
  const file = join(dir, path === "/" ? "index.html" : path);
  try {
    res.writeHead(200, { "content-type": mime[extname(file)] ?? "application/octet-stream" });
    res.end(await readFile(file));
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const browser = await chromium.launch({
  executablePath: process.env.CHROME_PATH || undefined,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--allow-loopback-in-peer-connection"],
});
let text = "";
let page;
try {
  const context = await browser.newContext({ permissions: ["microphone"] });
  page = await context.newPage();
  page.on("pageerror", (e) => console.error("[page error]", e.message));
  page.on("console", (m) => { if (m.type() === "error" || process.env.PAGE_LOG) console.error("[page console]", m.text()); });
  page.on("worker", (w) => w.on("console", (m) => { if (process.env.PAGE_LOG) console.error("[worker]", m.text()); }));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async () => {
    try { (await navigator.mediaDevices.getUserMedia({ audio: true })).getTracks().forEach((t) => t.stop()); } catch {}
  });
  await page.evaluate((a) => { location.hash = a; }, address);
  await page.waitForFunction(() => /DONE \d+/.test(document.getElementById("status")?.textContent ?? ""),
                             null, { timeout: Number(process.env.PAGE_TIMEOUT ?? 240000) });
  text = await page.evaluate(() => document.getElementById("status").textContent);
} catch (e) {
  let partial = "";
  try { partial = await page.evaluate(() => document.getElementById("status")?.textContent ?? ""); } catch {}
  text = `${partial}FAIL the page ran: ${e.message}\nDONE 1\n`;
} finally {
  await browser.close();
  server.close();
}
process.stdout.write(text);
