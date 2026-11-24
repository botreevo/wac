#!/bin/sh
# The commits wac.lock pins, and what those pin, into wac's package cache.
#
#     sh tools/deps.sh
#     sh tools/deps.sh --list [lock]   # the `<url> <commit>` pairs it would fetch, and nothing else
#     LOCK=<file> sh tools/deps.sh      # another lock (packages/reckon/tools use this, /dev/stdin included)
#
# The work is projects/repo/tools/fill-cache.sh, shared by every project in this repository: a pin into the
# repository is written out of local history with `git archive`; anything else is fetched with git, from
# git.voltrevo.com when GitHub lacks the commit.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
top=$(git -C "$root" rev-parse --show-toplevel)
lock="${LOCK:-$root/wac.lock}"
if [ "${1:-}" = "--list" ]; then exec sh "$top/projects/repo/tools/fill-cache.sh" --list "${2:-$lock}"; fi
if [ "$lock" = "/dev/stdin" ]; then tmp=$(mktemp); cat > "$tmp"; lock="$tmp"; fi
exec sh "$top/projects/repo/tools/fill-cache.sh" "$lock"
