#!/bin/sh
# One tree hashed three ways must give one kt1 (design/system/0016 step 1):
#   1. the working tree, walked by wactrust;
#   2. the commit, read out of git by wactrust — every hash from the bytes, none from git's SHA-1 names;
#   3. the working tree, walked by tools/oracle/tree.mjs — another implementation, over js-sha3.
#     sh tools/agree.sh REPO [COMMIT]          (a clean checkout of COMMIT is made from REPO)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$1" && pwd); commit=${2:-HEAD}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$commit" | tar -x -C "$tmp"
a=$(wac "$here/dist/wactrust.wasm" tree "$tmp")
b=$(wac "$here/dist/wactrust.wasm" tree --git "$repo" "$commit")
c=$(node "$here/tools/oracle/tree.mjs" "$tmp")
n=$(git -C "$repo" ls-tree -r "$commit" | wc -l)
echo "working tree  $a"; echo "git commit    $b"; echo "oracle        $c"
[ "$a" = "$b" ] && [ "$b" = "$c" ] && echo "agree: $n files" || { echo "DISAGREE" >&2; exit 1; }
