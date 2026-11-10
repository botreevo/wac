#!/bin/sh
# One commit, three ways to its CID: obj add-git (git as a locator), obj add over a checkout, and the reference
# importer over the same checkout. They must agree.        sh packages/ipfs/tools/agree.sh REPO [COMMIT]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$1" && pwd); commit=${2:-HEAD}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$commit" | tar -x -C "$tmp/" 2>/dev/null || { mkdir -p "$tmp"; git -C "$repo" archive "$commit" | tar -x -C "$tmp"; }
a=$(wac "$here/dist/obj.wasm" add-git "$repo" "$commit" --store "$tmp.store")
b=$(wac "$here/dist/obj.wasm" add "$tmp" --store "$tmp.store")
c=$(node "$here/tools/oracle/add-dir.mjs" "$tmp")
rm -rf "$tmp.store"
echo "git     $a"; echo "dir     $b"; echo "oracle  $c"
[ "$a" = "$b" ] && [ "$b" = "$c" ] && echo "agree: $(git -C "$repo" ls-tree -r "$commit" | wc -l) files" || { echo DISAGREE >&2; exit 1; }
