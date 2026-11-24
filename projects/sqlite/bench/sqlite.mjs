// The benchmark workloads (bench/workloads.md) through SQLite's own wasm build.
//     node bench/sqlite.mjs 20000
import sqlite3InitModule from "@sqlite.org/sqlite-wasm";

const n = Number(process.argv[2] ?? 20000);
const sqlite3 = await sqlite3InitModule({ print: () => {}, printErr: () => {} });
let db = new sqlite3.oo1.DB(":memory:");
const enc = new TextEncoder();
let t0 = 0n, digest = 0;
const cache = new Map();

function start() { digest = 2166136261; t0 = process.hrtime.bigint(); }
function feed(s) { for (const b of enc.encode(s)) digest = Math.imul(digest ^ b, 16777619) >>> 0; }
function done(name) {
  const ns = process.hrtime.bigint() - t0;
  console.log(JSON.stringify({ name, ms: Number(ns / 1000n) / 1000, digest }));
}
// A prepared statement per SQL text, as the wac side caches its parse.
function q(sql, params = []) {
  let st = cache.get(sql);
  if (!st) { st = db.prepare(sql); cache.set(sql, st); }
  st.reset(true);
  if (params.length) st.bind(params);
  const rows = [];
  while (st.step()) rows.push(st.get([]));
  return rows;
}
function rows(rs) {
  for (const r of rs) {
    for (const v of r) {
      if (v === null) feed("N|");
      else if (typeof v === "number" && Number.isInteger(v)) feed(v + "|");
      else if (typeof v === "bigint") feed(v + "|");
      else if (typeof v === "number") feed("R|");
      else if (typeof v === "string") feed(v + "|");
      else feed("B|");
    }
    feed("\n");
  }
}
const TYPES = ["TimerAdded", "TimerCompleted", "TimerRecurred", "TimerExpiryUpdated", "EventSkipped", "TimerRemoved"];

start();
q("CREATE TABLE instances (id TEXT PRIMARY KEY, nickname TEXT NOT NULL)");
q("CREATE TABLE events (id TEXT PRIMARY KEY, instance_id TEXT NOT NULL, seq INTEGER NOT NULL, type TEXT NOT NULL, payload TEXT NOT NULL, timestamp INTEGER NOT NULL, UNIQUE (instance_id, seq))");
q("CREATE INDEX events_by_instance_seq ON events(instance_id, seq)");
q("BEGIN");
for (let i = 0; i < 8; i++) q("INSERT INTO instances VALUES (?, ?)", [`i${i}`, `instance ${i}`]);
for (let i = 0; i < n; i++) {
  q("INSERT INTO events (id, instance_id, seq, type, payload, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
    [`e${i}`, `i${i % 8}`, Math.floor(i / 8) + 1, TYPES[i % 6], `{"id":"t${i % 97}","n":${i}}`, 1700000000000 + i * 7]);
}
q("COMMIT");
done("insert");

start();
for (let k = 0; k < 10000; k++) rows(q("SELECT payload FROM events WHERE id = ?", [`e${(k * 7919) % n}`]));
done("point lookup x10000");

start();
const per = Math.floor(n / 8);
for (let k = 0; k < 1000; k++) {
  const lo = (k * 37) % (per > 50 ? per - 50 : 1);
  rows(q("SELECT id, seq FROM events WHERE instance_id = ? AND seq >= ? AND seq < ? ORDER BY seq", [`i${k % 8}`, lo, lo + 50]));
}
done("index range x1000");

start();
for (let k = 0; k < 10000; k++) rows(q("SELECT MAX(seq) FROM events WHERE instance_id = ?", [`i${k % 8}`]));
done("max by index x10000");

start();
for (let k = 0; k < 1000; k++) rows(q("SELECT id FROM events WHERE instance_id = ? ORDER BY seq DESC LIMIT 10", [`i${k % 8}`]));
done("order by limit x1000");

start();
for (let k = 0; k < 20; k++) rows(q("SELECT count(*) FROM events WHERE json_extract(payload, '$.id') = ?", [`t${k}`]));
done("json scan x20");

start();
for (let k = 0; k < 20; k++) rows(q("SELECT type, count(*), sum(timestamp), max(seq) FROM events GROUP BY type ORDER BY type"));
done("group by x20");

start();
for (let k = 0; k < 20; k++) {
  rows(q("SELECT i.nickname, count(*) FROM events e JOIN instances i ON i.id = e.instance_id WHERE e.type = ? GROUP BY i.nickname ORDER BY 1", [TYPES[k % 6]]));
}
done("join + group x20");

start();
for (let k = 0; k < 200; k++) rows(q("SELECT count(*) FROM events WHERE payload LIKE ?", [`%"n":${k}1%`]));
done("like scan x200");

start();
q("BEGIN");
for (let k = 0; k < 2000; k++) q("UPDATE events SET payload = json_set(payload, '$.x', ?) WHERE id = ?", [k, `e${(k * 31) % n}`]);
q("COMMIT");
rows(q("SELECT count(*), sum(length(payload)) FROM events"));
done("update x2000");

start();
q("DELETE FROM events WHERE seq % 5 = 0");
rows(q("SELECT count(*) FROM events"));
done("delete 20%");

start();
for (const st of cache.values()) st.finalize();
cache.clear();
const img = sqlite3.capi.sqlite3_js_db_export(db);
feed(`${img.length > 0}`);
done("serialize");

start();
db.close();
db = new sqlite3.oo1.DB(":memory:");
const p = sqlite3.wasm.allocFromTypedArray(img);
const F = sqlite3.capi.SQLITE_DESERIALIZE_FREEONCLOSE | sqlite3.capi.SQLITE_DESERIALIZE_RESIZEABLE;
db.checkRc(sqlite3.capi.sqlite3_deserialize(db.pointer, "main", p, img.length, img.length, F));
rows(q("SELECT count(*), max(seq) FROM events"));
done("deserialize");
