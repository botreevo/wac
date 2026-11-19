// test-lane: browser — drives Chromium through Playwright, which needs -A
// A page whose entry declares its first frames (`export Frame[] prerendered()`), in an actual browser: the frame is in
// the HTML, and the program adopts it — and of two layouts, the one that fits the window is shown and kept.
//
// `test/wac/prerender_test.wac` checks the markup the build writes. What it cannot check is the host's half
// (`documentSide` in `tools/build.wac`): that the page shows the frame before any script runs, that the program keeps
// the nodes it finds there rather than drawing new ones — the node a reader focused or typed into is the same node
// afterwards — that no mark is left, that what the reader did before the program listened reaches it, and that a
// frame which differs from the one drawn at build time is mended, the rest kept, and said on the console.
//
// **Before the program runs** is an init script's `DOMContentLoaded`: the document is parsed, and the program, whose
// script is started from a `blob:` URL the loader makes, has not run. Each scenario checks that it had not.
//
// **Skipped loudly** when there is no browser, in the words `packages/raster/test/live.test.ts` in wac uses.

import { buildPage, serve, waitInPage, findChromium } from "./harness.ts";
function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) {
    throw new Error(`assertEquals failed${msg === undefined ? "" : ` — ${msg}`}\n  got:  ${a}\n  want: ${b}`);
  }
}

const CHROMIUM = findChromium();
const cannotBecause = CHROMIUM.cannot;
if (cannotBecause !== "") {
  console.warn(
    `SKIPPING the hydration live test: ${cannotBecause}.\n` +
      `  test/wac/prerender_test.wac checks the first frame's markup without a browser; this is the one that adopts it.`,
  );
}

/** An init script: once the document is parsed, mark the nodes a test asks after, then do `act` as a reader would. */
const before = (act: string) => `
  document.addEventListener("DOMContentLoaded", () => {
    window.__pre = document.getElementById("app").hasAttribute("data-wac-pre");
    for (const id of ["what", "add", "items", "same", "when", "where", "drift"]) {
      const el = document.getElementById(id);
      if (el) el.__kept = true;
    }
    ${act}
  });`;

const hydrated = "!document.getElementById('app').hasAttribute('data-wac-pre')";

for (const mode of [[], ["--in-page"]]) {
  const where = mode.length ? " — on the page's own thread" : " — in a worker";

  Deno.test({
    name: `a first frame drawn at build time is shown, then adopted${where}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-hydratelive-" });
      let browser;
      let http: { port: number; stop(): Promise<void> } | undefined;
      try {
        await buildPage("example/todofirst.wac", dir, mode);
        const port = (http = serve(dir)).port;
        browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });

        // With no script at all, the frame is there.
        const still = await (await browser.newContext({ javaScriptEnabled: false })).newPage();
        await still.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
        assertEquals(await still.textContent("h1"), "To do", "the heading, before any script");
        assertEquals(await still.isVisible("#add"), true, "the button, before any script");

        const page = await browser.newPage();
        const failures: string[] = [];
        const said: string[] = [];
        page.on("pageerror", (e: Error) => failures.push(String(e)));
        page.on("console", (m: { type(): string; text(): string }) => {
          said.push(m.text());
          if (m.type() === "error") failures.push(m.text());
        });
        await page.addInitScript(before(""));
        await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
        await waitInPage(page, hydrated, null, { timeout: 30_000 });
        assertEquals(await page.evaluate("window.__pre"), true, "the program had not run when the page was parsed");
        assertEquals(await page.evaluate("['what', 'add', 'items'].every((id) => document.getElementById(id).__kept)"), true,
                     "the field, the button and the list are the nodes that were parsed");
        assertEquals(await page.evaluate("document.querySelectorAll('[data-wac-h]').length"), 0, "no handle is left marked");
        assertEquals(await page.evaluate(
          "document.createTreeWalker(document.getElementById('app'), NodeFilter.SHOW_COMMENT).nextNode() === null"), true,
          "no comment is left");
        assertEquals(await page.evaluate("document.querySelector('#app h1').childNodes.length"), 1, "the heading's text is not doubled");
        assertEquals(said.filter((l) => l.startsWith("wac: hydrated")), [], "nothing drifted");

        // And it is the page it always was.
        await page.fill("#what", "bread");
        await page.click("#add");
        await waitInPage(page, "document.getElementById('count').textContent === '1 to do'", null, { timeout: 10_000 });
        assertEquals(failures, [], "the page reported an error");
      } finally {
        await browser?.close();
        await http?.stop();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });

  Deno.test({
    name: `what the reader did before the program listened reaches it${where}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-hydratelive-" });
      let browser;
      let http: { port: number; stop(): Promise<void> } | undefined;
      try {
        await buildPage("example/todofirst.wac", dir, mode);
        const port = (http = serve(dir)).port;
        browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });

        // Typed into the field and clicked add, before the program ran.
        const page = await browser.newPage();
        await page.addInitScript(before(`
          const what = document.getElementById("what");
          what.focus();
          what.value = "milk";
          what.dispatchEvent(new InputEvent("input", { bubbles: true, data: "milk", inputType: "insertText" }));
          document.getElementById("add").dispatchEvent(new MouseEvent("click", { bubbles: true }));
          window.__early = (window.wacEarly ?? []).length;
        `));
        await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
        await waitInPage(page, hydrated, null, { timeout: 30_000 });
        assertEquals(await page.evaluate("window.__pre && window.__early"), 2, "typed and clicked before the program ran");
        await waitInPage(page, "document.getElementById('count').textContent === '1 to do'", null, { timeout: 10_000 });
        assertEquals(await page.textContent("#items"), "milk", "the early click added what was typed early");
        assertEquals(await page.inputValue("#what"), "", "and the program cleared the field, as it does after adding");
        assertEquals(await page.evaluate("document.activeElement === document.getElementById('what')"), true,
                     "the field the reader focused still has the focus");

        // Typed, with no click: the first frame's empty value does not wipe it, and the program heard it.
        const typed = await browser.newPage();
        await typed.addInitScript(before(`
          const what = document.getElementById("what");
          what.value = "eggs";
          what.dispatchEvent(new InputEvent("input", { bubbles: true, data: "eggs", inputType: "insertText" }));
        `));
        await typed.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
        await waitInPage(typed, hydrated, null, { timeout: 30_000 });
        assertEquals(await typed.inputValue("#what"), "eggs", "what was typed early is still in the field");
        await typed.click("#add");
        await waitInPage(typed, "document.getElementById('count').textContent === '1 to do'", null, { timeout: 10_000 });
        assertEquals(await typed.textContent("#items"), "eggs", "and adding adds it");
      } finally {
        await browser?.close();
        await http?.stop();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });

  Deno.test({
    name: `a first frame that differs from the one drawn at build time is mended, the rest kept${where}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-hydratelive-" });
      let browser;
      let http: { port: number; stop(): Promise<void> } | undefined;
      try {
        await buildPage("example/drift.wac", dir, mode);
        const port = (http = serve(dir)).port;
        browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });
        const page = await browser.newPage();
        const said: string[] = [];
        page.on("console", (m: { text(): string }) => said.push(m.text()));
        await page.addInitScript(before(""));
        await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
        await waitInPage(page, hydrated, null, { timeout: 30_000 });
        assertEquals(await page.textContent("#when"), "in the browser", "the text that differs is the browser's");
        assertEquals(await page.evaluate("document.getElementById('where').innerHTML"), "<i>run</i>",
                     "the element that differs is the browser's");
        assertEquals(await page.evaluate("['drift', 'same', 'when', 'where'].every((id) => document.getElementById(id).__kept)"),
                     true, "everything else is the node that was parsed");
        await waitInPage(page, "true", null, { timeout: 100 });
        assertEquals(said.filter((l) => l.startsWith("wac: hydrated")), ["wac: hydrated — 8 kept, 1 made, 1 removed"],
                     "the drift is said");
      } finally {
        await browser?.close();
        await http?.stop();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });

  Deno.test({
    name: `of two layouts drawn at build time, the window's is shown before any script and kept${where}`,
    ignore: cannotBecause !== "",
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async () => {
      const { chromium } = await import("npm:playwright@1");
      const dir = await Deno.makeTempDir({ prefix: "wac-hydratelive-" });
      let browser;
      let http: { port: number; stop(): Promise<void> } | undefined;
      try {
        await buildPage("example/layouts.wac", dir, mode);
        const port = (http = serve(dir)).port;
        browser = await chromium.launch({ executablePath: CHROMIUM.executablePath, args: ["--no-proxy-server"] });
        for (const [width, height, nav, size] of [[390, 844, "tabs", "390x844"], [1280, 800, "side", "1280x800"]] as const) {
          // Before any script: the stylesheet shows the frame the window's width matches.
          const still = await (await browser.newContext({ javaScriptEnabled: false, viewport: { width, height } })).newPage();
          await still.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
          assertEquals(await still.isVisible(`#${nav}`), true, `at ${width} wide, before any script, the ${nav} layout is shown`);
          assertEquals(await still.locator("#layout").count(), 2, "both frames are in the page");

          // With script: the same layout is kept, as the nodes that were parsed, and nothing drifted.
          const page = await (await browser.newContext({ viewport: { width, height } })).newPage();
          const said: string[] = [];
          page.on("console", (m: { text(): string }) => said.push(m.text()));
          await page.addInitScript(`document.addEventListener("DOMContentLoaded", () => {
            window.__pre = document.getElementById("app").hasAttribute("data-wac-pre");
            for (const el of document.querySelectorAll("#${nav}")) if (el.offsetParent !== null || el.getClientRects().length) el.__kept = true;
          });`);
          await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: "load" });
          await waitInPage(page, hydrated, null, { timeout: 30_000 });
          assertEquals(await page.evaluate("window.__pre"), true, "the program had not run when the page was parsed");
          assertEquals(await page.locator("#layout").count(), 1, "one frame is left");
          assertEquals(await page.evaluate(`document.getElementById("${nav}").__kept === true`), true,
                       `at ${width} wide, the ${nav} shown before any script is the node the program kept`);
          assertEquals(await page.evaluate("document.querySelectorAll('[data-wac-frame], [data-wac-frames]').length"), 0,
                       "no frame wrapper or its stylesheet is left");
          // The text the program drew with the window's real size, where the frame said the size it was drawn at.
          assertEquals(await page.textContent("#size"), `${width}x${height}`, "the program was told the window's size");
          await waitInPage(page, "true", null, { timeout: 100 });
          assertEquals(said.filter((l) => l.startsWith("wac: hydrated")), [], `nothing drifted: ${size} was drawn for this window`);
        }
      } finally {
        await browser?.close();
        await http?.stop();
        await Deno.remove(dir, { recursive: true });
      }
    },
  });
}
