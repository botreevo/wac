// Read a CAR with the reference library and re-hash every block: what obj car writes, anyone can check.
import { CarReader } from '@ipld/car'
import { sha256 } from 'multiformats/hashes/sha2'
import fs from 'node:fs'
const r = await CarReader.fromBytes(fs.readFileSync(process.argv[2]))
let n = 0
for await (const { cid, bytes } of r.blocks()) { const d = await sha256.digest(bytes); if (!d.bytes.every((b, i) => b === cid.multihash.bytes[i])) throw new Error('bad ' + cid); n++ }
console.log((await r.getRoots())[0].toString(), n, 'blocks verified')
