// Runs both sides and prints them side by side, with whether their answers agree.
//     node bench/run.mjs 20000      (from the repository root; builds the wac side first)
import { execFileSync } from "node:child_process";

const n = process.argv[2] ?? "20000";
const wac = process.env.WAC ?? "wac";
execFileSync(wac, ["build", "bench/wac.wac", "-o", "dist/bench"], { stdio: "inherit" });
const parse = (out) => out.trim().split("\n").filter((l) => l.startsWith("{")).map((l) => JSON.parse(l));
const ours = parse(execFileSync(wac, ["dist/bench.wasm", n], { encoding: "utf8", maxBuffer: 1 << 26 }));
const theirs = parse(execFileSync("node", ["bench/sqlite.mjs", n], { encoding: "utf8", maxBuffer: 1 << 26 }));
const pad = (s, w) => String(s).padEnd(w);
const lpad = (s, w) => String(s).padStart(w);
console.log(`N = ${n}`);
console.log(pad("workload", 24) + lpad("wac-sqlite", 12) + lpad("sqlite-wasm", 12) + lpad("ratio", 8) + "  answers");
let total = [0, 0];
for (const t of theirs) {
  const o = ours.find((x) => x.name === t.name);
  if (!o) { console.log(pad(t.name, 24) + "  (missing on the wac side)"); continue; }
  total[0] += o.ms; total[1] += t.ms;
  const same = o.digest === t.digest ? "same" : "DIFFERENT";
  console.log(pad(t.name, 24) + lpad(o.ms.toFixed(1), 12) + lpad(t.ms.toFixed(1), 12) + lpad((o.ms / t.ms).toFixed(2) + "x", 8) + "  " + same);
}
console.log(pad("total", 24) + lpad(total[0].toFixed(1), 12) + lpad(total[1].toFixed(1), 12) + lpad((total[0] / total[1]).toFixed(2) + "x", 8));
