// Open a built page in headless Chromium with WebGPU on (SwiftShader's software Vulkan when there is no GPU), and
// wait for its title to give a verdict: `PASS …`, `FAIL …` or `NO GPU …`. Exits 0 only on PASS.
//
//     node tools/gpucheck.js dist/gpucheck
//
// Chromium and Playwright are the caller's; this is the one piece of JavaScript in the repository, because a GPU is
// only reachable from a browser.
const http = require("http");
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const dir = path.resolve(process.argv[2] ?? "dist/gpucheck");
const timeout = Number(process.argv[3] ?? 600) * 1000;

// WebGPU needs a secure context, which a page on localhost is and a file:// page is not in every browser.
const server = http.createServer((req, res) => {
  const file = path.join(dir, decodeURIComponent(req.url.split("?")[0]).replace(/\/$/, "/index.html"));
  if (!file.startsWith(dir) || !fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { "content-type": file.endsWith(".html") ? "text/html" : "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});

server.listen(0, "127.0.0.1", async () => {
  const browser = await chromium.launch({ args: ["--enable-unsafe-webgpu", "--use-angle=swiftshader", "--enable-features=Vulkan"] });
  const page = await browser.newPage();
  page.on("console", (m) => console.log("console:", m.text()));
  page.on("pageerror", (e) => console.log("pageerror:", e.message));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  let verdict = "TIMEOUT";
  try {
    await page.waitForFunction(() => /^(PASS|FAIL|NO GPU)/.test(document.title), null, { timeout, polling: 250 });
    verdict = await page.title();
  } catch (e) {
    verdict = "TIMEOUT, the title still " + JSON.stringify(await page.title());
  }
  console.log(verdict);
  await browser.close();
  server.close();
  process.exit(verdict.startsWith("PASS") ? 0 : 1);
});
