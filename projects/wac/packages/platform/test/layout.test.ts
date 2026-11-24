// `--target browser --layout files`: the directory a Manifest V3 extension can load, checked for its shape without a
// browser. `csp_live.test.ts` runs it in Chromium under the CSP that shape exists for.
import { buildApp } from "../build.ts";

function assert(ok: boolean, msg: string): void {
  if (!ok) throw new Error(msg);
}

Deno.test("--layout files writes a page with no inline script, a module launcher, a worker and the module beside them", async () => {
  const dir = await Deno.makeTempDir({ prefix: "wac-layout-" });
  try {
    await buildApp("packages/platform/example/hostget.wac", `${dir}/app`, { net: true }, "browser", false, { layout: "files" });
    const names = [...Deno.readDirSync(`${dir}/app`)].map((e) => e.name).sort();
    assert(JSON.stringify(names) === JSON.stringify(["app.wasm", "index.html", "launcher.js", "worker.js"]), `wrote ${names}`);
    const page = await Deno.readTextFile(`${dir}/app/index.html`);
    // Every <script> names a file: an extension's CSP refuses the inline kind outright.
    const scripts = [...page.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g)];
    assert(scripts.length === 1, `${scripts.length} scripts`);
    assert(/src="launcher\.js"/.test(scripts[0][0]) && scripts[0][1].trim() === "", `an inline script: ${scripts[0][0]}`);
    assert(/type="module"/.test(scripts[0][0]), "the launcher is not a module");
    const launcher = await Deno.readTextFile(`${dir}/app/launcher.js`);
    // The worker is started by URL, and its source is not carried inline to be made a `blob:` from.
    assert(/workerUrl:\s*new URL\("worker\.js"/.test(launcher), "the launcher does not start worker.js by URL");
    assert(!/workerSource:/.test(launcher), "the launcher still carries the worker's source");
    const worker = await Deno.readTextFile(`${dir}/app/worker.js`);
    assert(!worker.includes("const WASM ="), "the worker still carries the module as base64");
    assert(worker.includes("app.wasm"), "the worker does not fetch app.wasm");
    const wasm = await Deno.readFile(`${dir}/app/app.wasm`);
    assert(wasm[0] === 0 && wasm[1] === 0x61 && wasm[2] === 0x73 && wasm[3] === 0x6d, "app.wasm is not a module");
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("--layout files is a browser layout", async () => {
  let refused = "";
  try {
    await buildApp("packages/platform/example/hostget.wac", "/nonexistent/x", {}, "deno", false, { layout: "files" });
  } catch (e) {
    refused = e instanceof Error ? e.message : String(e);
  }
  assert(refused.includes("--target browser"), `refused with: ${refused}`);
});

Deno.test("a browser build names no staging directory, so two builds of one program are the same bytes", async () => {
  // The bundler writes each module's path into its output, and the staging directory is in that path — under a random
  // name, or the cache key. Neither is the program (`issues/system/0454e`).
  const dir = await Deno.makeTempDir({ prefix: "wac-repro-" });
  try {
    await buildApp("packages/platform/example/hostget.wac", `${dir}/files`, { net: true }, "browser", false, { layout: "files" });
    await buildApp("packages/platform/example/hostget.wac", `${dir}/page.html`, { net: true }, "browser");
    const texts = [
      await Deno.readTextFile(`${dir}/files/launcher.js`),
      await Deno.readTextFile(`${dir}/files/worker.js`),
      await Deno.readTextFile(`${dir}/page.html`),
    ];
    for (const t of texts) {
      assert(!/wac-app-[0-9a-zA-Z]{4,}/.test(t), "a random staging name is in the output");
      assert(!/stage\/[0-9a-f]{16,}/.test(t), "the cache key's staging name is in the output");
    }
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});
