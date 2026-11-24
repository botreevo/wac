// Admitted trees, kept in the extension's Origin Private File System: `trees/<cid>/` holds the tree's files as
// admission wrote them out from verified blocks (`claim run --out`, which in the page's worker writes to this same
// OPFS). Nothing else writes here, and nothing here is trusted for more than that.

async function dirAt(root, parts, create) {
  let d = root;
  for (const p of parts) d = await d.getDirectoryHandle(p, { create });
  return d;
}

/** Every file below `dir`, as path → bytes. */
async function readAll(dir, prefix, out) {
  for await (const [name, h] of dir.entries()) {
    const path = prefix + name;
    if (h.kind === 'directory') await readAll(h, path + '/', out);
    else out.set(path, new Uint8Array(await (await h.getFile()).arrayBuffer()));
  }
  return out;
}

/** The tree under `cid`, read whole into memory: `{ read(path) → Uint8Array | null, paths }`; null if absent. */
export async function openTree(cid) {
  let dir;
  try { dir = await dirAt(await navigator.storage.getDirectory(), ['trees', cid], false); } catch { return null; }
  const files = await readAll(dir, '', new Map());
  return { cid, paths: [...files.keys()].sort(), read: (p) => files.get(p) ?? null };
}

/** Write a tree (path → bytes): for tests, and for an admission that hands its files over rather than writing them. */
export async function writeTree(cid, files) {
  const root = await dirAt(await navigator.storage.getDirectory(), ['trees', cid], true);
  for (const [path, bytes] of files) {
    const parts = path.split('/');
    const d = await dirAt(root, parts.slice(0, -1), true);
    const w = await (await d.getFileHandle(parts[parts.length - 1], { create: true })).createWritable();
    await w.write(bytes); await w.close();
  }
}
