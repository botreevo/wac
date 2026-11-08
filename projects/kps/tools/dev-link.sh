#!/bin/sh
# Point the locked wac commit at a local checkout, so edits there are seen here without a commit.
#
#     sh tools/dev-link.sh ~/src/wac
#
# wac's package cache is one plain checkout per locked commit (`$WAC_HOME/cache/git/<escaped url>/<commit>`).
# During development the transport work lands in wac's own packages, so this makes that cache entry a symlink
# to the checkout being edited. **It is for development only**: a release pins a commit that exists upstream
# and fills the cache with a real checkout of it (`sh tools/fill-cache.sh`).
set -eu
clone=$(cd "${1:?usage: dev-link.sh <wac checkout>}" && pwd)
root=$(cd "$(dirname "$0")/.." && pwd)
commit=$(tr '\n' ' ' < "$root/wac.lock" | sed -n 's/.*"wac" *: *{[^}]*"commit" *: *"\([0-9a-f]\{40\}\)".*/\1/p')
[ -n "$commit" ] || { echo "dev-link: no wac commit in wac.lock" >&2; exit 1; }
dir="${WAC_HOME:-$HOME/.wac}/cache/git/https%3A%2F%2Fgithub.com%2Fvoltrevo%2Fwac.git"
mkdir -p "$dir"
rm -rf "$dir/$commit"
ln -s "$clone" "$dir/$commit"
echo "dev-link: wac $commit -> $clone"
