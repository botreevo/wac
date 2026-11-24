#!/bin/sh
# Put the wac commit wac.lock pins into wac's package cache from a local clone, without `wac update` or a network.
#
#     sh tools/use-local-wac.sh /path/to/a/clone/of/wac
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
repo=${1:?usage: use-local-wac.sh <path to a clone of wac>}
url=$(tr '\n' ' ' < "$root/wac.lock" | sed -n 's/.*"wac": *{[^}]*"git": *"\([^"]*\)".*/\1/p')
commit=$(tr '\n' ' ' < "$root/wac.lock" | sed -n 's/.*"wac": *{[^}]*"commit": *"\([0-9a-f]\{40\}\)".*/\1/p')
[ -n "$commit" ] || { echo "use-local-wac.sh: no commit for wac in wac.lock" >&2; exit 1; }
git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || git -C "$repo" fetch -q origin "$commit"
key=$(printf '%s' "$url" | sed 's/:/%3A/g; s#/#%2F#g')
dest="${WAC_HOME:-$HOME/.wac}/cache/git/$key/$commit"
if [ ! -f "$dest/pack.pack" ]; then
  mkdir -p "$dest"
  git -C "$repo" archive "$commit" | tar -x -C "$dest"
  touch "$dest/pack.pack"     # the cache's "this checkout is complete" marker
fi
echo "wac $commit is in the cache"
