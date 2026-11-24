// Compile every shader `wac task shaders` prints — sections headed `//// <name>` — in headless Chromium's WebGPU, and
// say which do not compile and why. A WGSL mistake found without running a model.
//
//     wac run tools/shaders.wac > dist/shaders.txt && node tools/shadercheck.js dist/shaders.txt
const fs = require("fs");
const http = require("http");
const { chromium } = require("playwright");

const text = fs.readFileSync(process.argv[2], "utf8");
const parts = text.split(/^\/\/\/\/ /m).filter((s) => s.trim()).map((s) => {
  const nl = s.indexOf("\n");
  return [s.slice(0, nl), s.slice(nl + 1)];
});

// WebGPU needs a secure context: an empty page served from localhost is one, `about:blank` is not.
const server = http.createServer((req, res) => { res.writeHead(200, { "content-type": "text/html" }); res.end("<!doctype html>"); });
server.listen(0, "127.0.0.1", async () => {
  const browser = await chromium.launch({ args: ["--enable-unsafe-webgpu", "--use-angle=swiftshader", "--enable-features=Vulkan"] });
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const failures = await page.evaluate(async (parts) => {
    const device = await (await navigator.gpu.requestAdapter()).requestDevice();
    const out = [];
    for (const [name, code] of parts) {
      device.pushErrorScope("validation");
      const module = device.createShaderModule({ code });
      const info = await module.getCompilationInfo();
      device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: "main" } });
      const err = await device.popErrorScope();
      const msgs = info.messages.filter((m) => m.type === "error").map((m) => m.lineNum + ": " + m.message);
      if (msgs.length || err) out.push(name + ": " + msgs.join(" | ") + (err ? " [" + err.message.split("\n")[0] + "]" : ""));
    }
    return out;
  }, parts);
  console.log(`${parts.length} shaders, ${failures.length} that do not compile`);
  for (const f of failures) console.log(f);
  await browser.close();
  server.close();
  process.exit(failures.length === 0 ? 0 : 1);
});
