#!/bin/sh
# The commits this project's wac.lock pins, and what those pin, into wac's package cache.
#
#     sh tools/fill-cache.sh
#     sh tools/fill-cache.sh --list [lock]   # the `<url> <commit>` pairs it would fill, and nothing else
#
# The work is projects/repo/tools/fill-cache.sh, shared by every project in this repository: a pin into the
# repository is written out of local history with `git archive`; anything else is fetched with git.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
top=$(git -C "$root" rev-parse --show-toplevel)
if [ "${1:-}" = "--list" ]; then exec sh "$top/projects/repo/tools/fill-cache.sh" --list "${2:-$root/wac.lock}"; fi
exec sh "$top/projects/repo/tools/fill-cache.sh" "$root/wac.lock"
