// The reference importer over a directory, as obj add walks one: hidden files included, `.git` at the top left out,
// symlinks refused. Prints the root CID under IPIP-0499's `unixfs-v1-2025` profile.
import { importer } from 'ipfs-unixfs-importer'
import fs from 'node:fs'
import path from 'node:path'
const root = process.argv[2]
const entries = []
const walk = (rel) => {
  const names = fs.readdirSync(path.join(root, rel))
  if (names.length === 0 && rel) entries.push({ path: 'root/' + rel })
  for (const n of names) {
    if (!rel && n === '.git') continue
    const r = rel ? rel + '/' + n : n
    const st = fs.lstatSync(path.join(root, r))
    if (st.isSymbolicLink()) throw new Error(r + ': symlink')
    if (st.isDirectory()) walk(r)
    else entries.push({ path: 'root/' + r, content: fs.readFileSync(path.join(root, r)) })
  }
}
walk('')
const bs = { put: async (cid) => cid, get: async () => { throw new Error('unused') }, has: async () => false }
let cid; for await (const e of importer(entries, bs, { profile: 'unixfs-v1-2025' })) if (e.path === 'root') cid = e.cid
console.log(cid.toString())
