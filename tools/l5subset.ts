// **What the bootstrap asks of wacc, checked in seconds** — `wac task check:l5`.
//
// wac-L5 builds wacc from source (`bootstrap/ts/selfhost.ts`), so wacc's own files are held to more than the
// language: they must be written in the subset wac-L5 reads, their top-level names must be unique across the whole
// graph (the flattener would rename a collision, and the one program it must not rename anything in is the compiler
// — `packages/wacc/README.md`, "One thing the bootstrap asks of this package"), and what the self-host check builds
// must need nothing from a host. The full gate says so through `bootstrap/ts/l5.test.ts` and `selfhost.test.ts`,
// an hour after the edit and in words that are hard to act on: *line 45730 of the flattened graph*, or
// *Import #0 "wac": module is not an object or function*. This says it at once, at the file and line.
//
// Three checks:
//
//   - **names**: a top-level name declared in two of wacc's files;
//   - **subset**: what wac-L5 does not parse — `string.fromBytes([(48 + d) as~ u8])` was this afternoon's — placed on
//     the source line it came from. Only the first: wac-L5 does not recover, so the refusals after it are where its
//     parser lost its place, and placing them sends a reader to lines that are fine;
//   - **interpolation**: `"\{x}"` in a file the self-host check builds. wac-L5 reads it, and the wacc it builds lowers
//     it to a host import that the check's bare instantiation does not provide, so round 1 fails to start. Text
//     built with `+` has no such import.
//
// Run: `deno run -A tools/l5subset.ts` (what the task runs). Exit 0 when all three are clean.

import { flatten as flattenText, l5ToL0 } from "../bootstrap/ts/l5.ts";
import { flatten as flattenWith } from "../bootstrap/js/flatten.js";
import { files as hostFiles } from "../bootstrap/hosts/deno.js";

const ROOT = await Deno.realPath(new URL("..", import.meta.url).pathname);
const API = `${ROOT}/packages/wacc/src/api.wac`;
// The self-host check's entry: kept with the drivers, and built as though it sat in `packages/wacc/src`.
const SELFCHECK = `${ROOT}/bootstrap/drivers/selfcheck.wac`;
const SELFCHECK_AS = `${ROOT}/packages/wacc/src/selfcheck.wac`;
const DRIVER = `${ROOT}/bootstrap/drivers/spec_cases.wac`;

/**
 * Every file `entry` reaches through relative imports, repo-relative, with its text. `as` is where the entry is
 * taken to be, for one kept somewhere other than where it is built.
 */
async function closure(entry: string, as = entry): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  async function visit(abs: string, at: string): Promise<void> {
    const real = await Deno.realPath(abs);
    const rel = real.slice(ROOT.length + 1);
    if (out.has(rel)) return;
    const text = await Deno.readTextFile(real);
    out.set(rel, text);
    const dir = at.slice(0, at.lastIndexOf("/"));
    for (const m of text.matchAll(/^\s*import\s*\{[^}]*\}\s*from\s*"([^"]+)"\s*;/gm)) {
      if (m[1].startsWith(".")) {
        const next = await Deno.realPath(`${dir}/${m[1]}`);
        await visit(next, next);
      }
    }
  }
  await visit(entry, as);
  return out;
}

/** A line of code with its comments and string contents out of the way — what is left is what a parser reads. */
function isComment(line: string): boolean {
  const t = line.trimStart();
  return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*");
}

const problems: string[] = [];

// ── names ────────────────────────────────────────────────────────────────────────────────────────
const collided: string[] = [];
await flattenWith(API, hostFiles, (what: string) => collided.push(what));
for (const c of collided.sort()) {
  problems.push(`names: ${c} — give one a distinct name, or keep one and import it`);
}

// ── subset ───────────────────────────────────────────────────────────────────────────────────────
const graph = await closure(API);
const flat = await flattenText(API) + "\n" + await Deno.readTextFile(DRIVER);
const flatLines = flat.split("\n");
const l0 = await l5ToL0(flat);
const refusals = l0.split("\n").filter((l) => l.startsWith("!!"));
/** Where a line of the flattened graph came from: the source lines with the same text, outside comments. */
function placed(text: string): string {
  const want = text.trim();
  if (want === "") return "(a blank line of the flattened graph)";
  const hits: string[] = [];
  for (const [path, src] of graph) {
    const lines = src.split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].trim() === want && !isComment(lines[i])) hits.push(`${path}:${i + 1}`);
    }
  }
  return hits.length === 0 ? `(renamed in flattening: ${want.slice(0, 80)})` : hits.slice(0, 3).join(", ");
}
if (refusals.length > 0) {
  const m = /line (\d+): (.*)$/.exec(refusals[0]);
  const after = refusals.length > 1 ? ` (and ${refusals.length - 1} more after it, where wac-L5's parser lost its place)` : "";
  problems.push(m === null
    ? `subset: ${refusals[0].slice(3)}${after}`
    : `subset: ${placed(flatLines[Number(m[1]) - 1] ?? "")} — wac-L5: ${m[2]}${after}`);
}

// ── interpolation ────────────────────────────────────────────────────────────────────────────────
// `\{` that is not itself escaped (`\\{` is a backslash and a brace, which generated source carries as text).
const interpolated = /(?<!\\)\\\{/;
for (const [path, src] of await closure(SELFCHECK, SELFCHECK_AS)) {
  if (!path.startsWith("packages/wacc/") && !path.startsWith("bootstrap/drivers/")) continue;
  const lines = src.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!isComment(lines[i]) && interpolated.test(lines[i])) {
      problems.push(`interpolation: ${path}:${i + 1} — build this text with \`+\`: ${lines[i].trim().slice(0, 90)}`);
    }
  }
}

if (problems.length === 0) {
  console.log(`check:l5: wacc's ${graph.size} files are in wac-L5's subset, their names are distinct, and the ` +
    `self-host check's files interpolate nothing`);
  Deno.exit(0);
}
console.error(`check:l5: ${problems.length} problem(s) the bootstrap would hit — packages/wacc/README.md, ` +
  `"One thing the bootstrap asks of this package":`);
for (const p of problems) console.error(`  ${p}`);
Deno.exit(1);
