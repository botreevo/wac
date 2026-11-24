#!/bin/sh
# The install line from before wac moved into projects/wac, kept working:
#
#     curl -fsSL https://raw.githubusercontent.com/voltrevo/wac/master/bootstrap.sh | sh -s -- --host deno
#
# It hands its arguments to projects/wac/bootstrap.sh, which is the build — the one in this clone when run from
# one, and otherwise fetched from where this came from. Nothing else belongs here.
set -eu
here=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || here=""
if [ -n "$here" ] && [ -f "$here/projects/wac/bootstrap.sh" ]; then
  exec sh "$here/projects/wac/bootstrap.sh" "$@"
fi
url="${WAC_BOOTSTRAP_URL:-https://raw.githubusercontent.com/voltrevo/wac/master/projects/wac/bootstrap.sh}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" | sh -s -- "$@"
else
  wget -qO- "$url" | sh -s -- "$@"
fi
