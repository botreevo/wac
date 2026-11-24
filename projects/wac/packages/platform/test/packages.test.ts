// A program whose project pins a package, built by the Deno-side builders — `native.ts` and `build.ts`.
//
// Their own file walk (`harness/wacFiles.ts`) knows relative, `@/`, `core` and `std` imports and not a `wac.lock`,
// so a project importing a package by name (all of wac-eth imports `"wac"`) failed with every such import
// unresolved, though `wac build` compiled it. They now ask the command for the graph (`wacFilesFromCommand`), and
// these tests hold that: the package's file is in the module, under a path with `%` in it as the package cache's
// own paths have (`https%3A%2F%2F…`), and a `--target browser` page builds from the same project.
import { buildNative } from "../native.ts";
import { buildApp } from "../build.ts";

function assert(ok: boolean, msg: string): void {
  if (!ok) throw new Error(msg);
}

const REPO = "https://example.invalid/dep.git";
/** `REPO` as the cache spells a directory — `packages/wacpkg/src/cache.wac`'s `escapeRepo`. */
const ESCAPED = "https%3A%2F%2Fexample.invalid%2Fdep.git";
const COMMIT = "0123456789abcdef0123456789abcdef01234567";

/** A project pinning `dep`, the dependency in a cache of its own, and `WAC_HOME` pointing at it. */
async function pinned(): Promise<{ dir: string; entry: string; restore: () => void }> {
  // **A `%` in the path on purpose** — the package cache's directories all have one, and a path that reaches a
  // `file://` URL undecoded names a different file.
  const dir = await Deno.makeTempDir({ prefix: "wac-pinned%25-" });
  const app = `${dir}/app`;
  const checkout = `${dir}/home/cache/git/${ESCAPED}/${COMMIT}`;
  await Deno.mkdir(app, { recursive: true });
  await Deno.mkdir(`${checkout}/src`, { recursive: true });
  await Deno.writeTextFile(`${app}/wac.json5`, `{ imports: { dep: { git: "${REPO}", ref: "main", subdir: "./src" } } }\n`);
  await Deno.writeTextFile(
    `${app}/wac.lock`,
    `{ imports: { dep: { git: "${REPO}", ref: "main", subdir: "./src", commit: "${COMMIT}" } } }\n`,
  );
  await Deno.writeTextFile(`${app}/main.wac`, `import { two } from "dep";\nexport i32 four() { return two() * 2; }\n`);
  await Deno.writeTextFile(`${checkout}/src/wac.json5`, "{ exports: './lib.wac' }\n");
  await Deno.writeTextFile(`${checkout}/src/lib.wac`, `import { one } from "./one.wac";\nexport i32 two() { return one() + one(); }\n`);
  await Deno.writeTextFile(`${checkout}/src/one.wac`, "export i32 one() { return 1; }\n");
  // The cache's mark that a checkout is complete.
  await Deno.writeTextFile(`${checkout}/pack.pack`, "not a real pack\n");
  const was = Deno.env.get("WAC_HOME");
  Deno.env.set("WAC_HOME", `${dir}/home`);
  const restore = () => was === undefined ? Deno.env.delete("WAC_HOME") : Deno.env.set("WAC_HOME", was);
  return { dir, entry: `${app}/main.wac`, restore };
}

Deno.test("a project's locked package resolves through the Deno host, and its file is in the module", async () => {
  const { dir, entry, restore } = await pinned();
  try {
    await buildNative(entry, `${dir}/run`, {});
    const wasm = await Deno.readFile(`${dir}/run.wasm`);
    const { instance } = await WebAssembly.instantiate(wasm, {});
    const four = (instance.exports as Record<string, CallableFunction>)["four"];
    assert(typeof four === "function", "the module exports no `four`");
    assert(four() === 4, `four() answered ${four()}`);
  } finally {
    restore();
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("...and a `--target browser` page builds from the same project", async () => {
  const { dir, entry, restore } = await pinned();
  try {
    await buildApp(entry, `${dir}/page.html`, {}, "browser");
    const page = await Deno.readTextFile(`${dir}/page.html`);
    assert(page.includes("<script type=\"module\">"), "the page has no launcher");
    assert(page.length > 10000, `a ${page.length}-byte page cannot be carrying the module`);
  } finally {
    restore();
    await Deno.remove(dir, { recursive: true });
  }
});
