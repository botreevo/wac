// The vectors in test/vectors.json, from the reference JavaScript implementations rather than from the code under
// test: multiformats for CIDs, @ipld/dag-cbor, and ipfs-unixfs-importer with IPIP-0499's `unixfs-v1-2025` profile.
// File contents come from a xorshift32 generator that test/oracle.wac repeats, so only sizes and seeds are stored.
import { importer } from 'ipfs-unixfs-importer'
import { fixedSize } from 'ipfs-unixfs-importer/chunker'
import { balanced } from 'ipfs-unixfs-importer/layout'
import { MemoryBlockstore } from 'blockstore-core/memory'
import { CID } from 'multiformats/cid'
import * as raw from 'multiformats/codecs/raw'
import { sha256 } from 'multiformats/hashes/sha2'
import * as dagCbor from '@ipld/dag-cbor'
import { CarWriter } from '@ipld/car/writer'
import fs from 'node:fs'

const content = (n, seed) => { const b = new Uint8Array(n); let s = seed >>> 0 || 1; for (let i = 0; i < n; i++) { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; b[i] = s & 255 } return b }
const hex = (b) => Buffer.from(b).toString('hex')
const small = (chunk, width, shard) => ({ chunker: fixedSize({ chunkSize: chunk }), layout: balanced({ maxChildrenPerNode: width }), rawLeaves: true, cidVersion: 1,
  reduceSingleLeafToSelf: true, shardSplitThresholdBytes: shard, shardSplitStrategy: 'block-bytes', wrapWithDirectory: false })
async function addFile (bytes, opts) { const bs = new MemoryBlockstore(); let last; for await (const e of importer([{ content: bytes }], bs, opts)) last = e; return last.cid.toString() }
async function addTree (files, dirs, opts) {
  const bs = new MemoryBlockstore(); const entries = []
  for (const d of dirs) entries.push({ path: 'root/' + d })
  for (const f of files) entries.push({ path: 'root/' + f.path, content: content(f.size, f.seed) })
  let rootCid
  for await (const e of importer(entries, bs, opts)) if (e.path === 'root') rootCid = e.cid
  return rootCid.toString()
}
const out = { cids: [], files: [], trees: [], cbor: [] }

// CIDs of raw blocks, and base32 round trips
for (const [n, seed] of [[0, 1], [1, 2], [11, 3], [100, 4]]) {
  const b = content(n, seed); const c = CID.create(1, raw.code, await sha256.digest(b))
  out.cids.push({ size: n, seed, text: c.toString(), bytes: hex(c.bytes) })
}
// Files: the profile itself on sizes it can afford, and its exact algorithm at small parameters for deep trees
const profile = { profile: 'unixfs-v1-2025' }
out.files.push({ size: 11, seed: 0, text: 'hello world', chunk: 1048576, width: 1024, cid: await addFile(new TextEncoder().encode('hello world'), profile) })
for (const [n, seed] of [[0, 5], [1048576, 6], [1048577, 7], [3 * 1048576 + 5, 8]]) {
  out.files.push({ size: n, seed, chunk: 1048576, width: 1024, cid: await addFile(content(n, seed), profile) })
}
for (const [n, seed, chunk, width] of [[1, 9, 16, 4], [16, 10, 16, 4], [17, 11, 16, 4], [64, 12, 16, 4], [65, 13, 16, 4], [256, 14, 16, 4], [257, 15, 16, 4], [1000, 16, 16, 4], [5000, 17, 7, 3]]) {
  out.files.push({ size: n, seed, chunk, width, cid: await addFile(content(n, seed), small(chunk, width, 1 << 30)) })
}
// Directory trees under the profile: nesting, an empty directory, hidden files, names that sort bytewise
const tree1 = { files: [{ path: 'README.md', size: 120, seed: 21 }, { path: '.gitignore', size: 9, seed: 22 }, { path: 'src/a.wac', size: 2000, seed: 23 },
  { path: 'src/B.wac', size: 0, seed: 24 }, { path: 'src/deep/x/y.bin', size: 1048577, seed: 25 }, { path: 'é.txt', size: 3, seed: 26 }], dirs: ['empty'] }
out.trees.push({ ...tree1, chunk: 1048576, width: 1024, shard: 262144, cid: await addTree(tree1.files, tree1.dirs, profile) })
// The sharding boundary at small parameters: directory blocks of exactly the threshold stay plain, one byte more shards
const many = []; for (let i = 0; i < 40; i++) many.push({ path: `f${String(i).padStart(3, '0')}`, size: 1, seed: 100 + i })
const tree2 = { files: many, dirs: [] }
out.trees.push({ ...tree2, chunk: 1048576, width: 1024, shard: 1 << 20, cid: await addTree(many, [], small(1048576, 1024, 1 << 20)) })
// The boundary itself: the plain directory's block is S bytes; at threshold S it stays plain, at S - 1 it shards.
{
  const kept = new Map(); const bs = { put: async (cid, bytes) => { kept.set(cid.toString(), bytes); return cid }, get: async (cid) => kept.get(cid.toString()), has: async (cid) => kept.has(cid.toString()) }
  let root; for await (const e of importer(many.map(f => ({ path: 'root/' + f.path, content: content(f.size, f.seed) })), bs, small(1048576, 1024, 1 << 20))) if (e.path === 'root') root = e.cid
  const size = kept.get(root.toString()).length
  out.shardProbe = { size, atSize: await addTree(many, [], small(1048576, 1024, size)), belowSize: await addTree(many, [], small(1048576, 1024, size - 1)) }
}
// DAG-CBOR records
const c0 = CID.parse(out.cids[2].text)
const records = [
  { recipe: { machine: 'wasm-gc/det/1', format: 'unixfs-v1-2025+hidden', input: c0 } },
  { a: 1, bb: -2, c: 'text', d: new Uint8Array([1, 2, 3]), e: [true, false, null], f: { z: 0, y: 4294967296 } },
  { big: 1n << 62n, neg: -(1n << 40n), empty: {}, list: [] },
]
for (const r of records) { const b = dagCbor.encode(r); out.cbor.push({ hex: hex(b), cid: CID.create(1, dagCbor.code, await sha256.digest(b)).toString() }) }
// A CAR of tree1, written by the reference writer, for wac to read and check
{
  // A store that keeps each block under the CID it was put with (MemoryBlockstore keys by multihash and forgets the codec).
  const kept = new Map(); const bs = { put: async (cid, bytes) => { kept.set(cid.toString(), { cid, bytes }); return cid }, get: async (cid) => kept.get(cid.toString()).bytes, has: async (cid) => kept.has(cid.toString()) }
  const entries = []
  // tree1 without its 1 MiB file, so the fixture stays small
  const carFiles = tree1.files.filter(f => f.size < 100000)
  for (const d of tree1.dirs) entries.push({ path: 'root/' + d })
  for (const f of carFiles) entries.push({ path: 'root/' + f.path, content: content(f.size, f.seed) })
  let root; for await (const e of importer(entries, bs, profile)) if (e.path === 'root') root = e.cid
  const { writer, out: carOut } = CarWriter.create([root])
  const chunks = []; const done = (async () => { for await (const c of carOut) chunks.push(c) })()
  for (const { cid, bytes } of kept.values()) await writer.put({ cid, bytes })
  await writer.close(); await done
  fs.writeFileSync(new URL('../../test/tree1.car', import.meta.url), Buffer.concat(chunks))
  out.car = { root: root.toString(), files: carFiles, dirs: tree1.dirs, blocks: kept.size }
}
fs.writeFileSync(new URL('../../test/vectors.json', import.meta.url), JSON.stringify(out, null, 1) + '\n')
// The same, as wac source, so the tests need no filesystem: the JSON as a string, the CAR as hex.
const car = fs.readFileSync(new URL('../../test/tree1.car', import.meta.url))
fs.writeFileSync(new URL('../../test/vectors.wac', import.meta.url),
  '// Generated by tools/oracle/vectors.mjs from the reference JavaScript implementations. Do not edit.\n\n' +
  'export static string VECTORS = ' + JSON.stringify(JSON.stringify(out)) + ';\n\n' +
  'export static string TREE1_CAR = "' + car.toString('hex') + '";\n')
console.log(JSON.stringify(out, null, 0).slice(0, 1500))
