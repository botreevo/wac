#!/bin/sh
# Point the locked wac and web commits at this working tree, so edits in projects/wac and projects/web are seen
# here without a commit.
#
#     sh tools/dev-link.sh
#
# wac's package cache is one plain checkout per locked commit (`$WAC_HOME/cache/git/<escaped url>/<commit>`), and
# both pins name this repository, so both entries become symlinks into it. `web` is pinned at `subdir:
# ./projects/web`, so its entry is the top of the working tree; `wac` is pinned at a commit from before wac moved
# into projects/wac, with no subdir, so its entry is projects/wac itself. **It is for development only**: a
# release pins commits in this history and fills the cache with real checkouts (projects/repo/tools/fill-cache.sh).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
top=$(git -C "$root" rev-parse --show-toplevel)
dir="${WAC_HOME:-$HOME/.wac}/cache/git/https%3A%2F%2Fgithub.com%2Fvoltrevo%2Fwac.git"
mkdir -p "$dir"
link() {   # name target
  commit=$(tr '\n' ' ' < "$root/wac.lock" | sed -n "s/.*\"$1\" *: *{[^}]*\"commit\" *: *\"\([0-9a-f]\{40\}\)\".*/\1/p")
  [ -n "$commit" ] || { echo "dev-link: no $1 commit in wac.lock" >&2; exit 1; }
  rm -rf "$dir/$commit"
  ln -s "$2" "$dir/$commit"
  echo "dev-link: $1 $commit -> $2"
}
link wac "$top/projects/wac"
link web "$top"
