# ipfs

Objects as IPFS names them, under one exact encoding: IPIP-0499's **`unixfs-v1-2025`** profile — CIDv1 and
SHA-256, 1 MiB chunks, raw leaves, balanced trees of up to 1024 links — with hidden files included, symlinks refused
and no permissions or timestamps. The same bytes always get the same CID, and it is the CID any standard IPFS tool gives
them, so any IPFS node or gateway can serve them. Reckon's objects are these.

| | |
| --- | --- |
| `src/cid.wac` | CIDv1 (raw, dag-pb, dag-cbor; SHA-256 only), binary and base32 text |
| `src/dagpb.wac` | the protobuf node UnixFS is made of, written links-first and read strictly |
| `src/unixfs.wac`, `src/tree.wac` | files and directory trees under the profile, and reading nodes back |
| `src/dagcbor.wac` | DAG-CBOR for records: deterministic, strict, no floats |
| `src/car.wac` | CAR v1, every block checked on reading |
| `src/store.wac` | blocks kept under their CIDs (at `ipfs/<cid>`, the path a trustless gateway serves), resolving through mirrors, importing directories, git commits and CARs, exporting files and trees |
| `cmd/obj.wac` | `obj add`, `add-git`, `cat`, `ls`, `car`, `import-car` |

**Checked against the reference implementations**, not against itself: `tools/oracle/vectors.mjs` writes
`test/vectors.wac` with multiformats, @ipld/dag-cbor, @ipld/car and ipfs-unixfs-importer 16.1.1 under the profile.
The tests compare CIDs for raw blocks, files from one byte to multi-level trees, directory trees with hidden files,
empty directories and non-ASCII names, DAG-CBOR records byte for byte, and CARs both ways. `tools/agree.sh` hashes a
git commit three ways — through git, over a checkout, and with the reference importer over the same checkout — and
they agree on wac (4,050 files), wac-eth, wacuum and wac-ide.

**Not yet: HAMT sharding.** The profile shards a directory whose encoded node exceeds 256 KiB, roughly several thousand
entries. That boundary is implemented and tested exactly — at the threshold a directory stays plain, as the reference
does — but past it the directory is refused rather than encoded some other way. Nothing in the repositories above
comes near it.

    wac test packages/ipfs/test
    (cd packages/ipfs/tools/oracle && npm install && node vectors.mjs)    # regenerate the vectors
    wac build --allow-read --allow-write --allow-run packages/ipfs/cmd/obj.wac -o packages/ipfs/dist/obj
    sh packages/ipfs/tools/agree.sh <git repository>
