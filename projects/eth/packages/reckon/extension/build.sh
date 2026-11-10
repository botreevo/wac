#!/bin/sh
# Build what the extension runs and does not keep in git: admission, cmd/web.wac built with wac's
# `--target browser --layout files` into src/admit/ (index.html, launcher.js, worker.js, app.wasm).
#
#     WAC_SRC=/path/to/wac sh packages/reckon/extension/build.sh [OUT.zip]
#
# WAC_SRC is a checkout of wac at the commit wac.lock pins, at a path with no `%` in it; deno and `wac` on PATH.
# With OUT.zip, the extension is also packed as a zip to load or publish (src/ as its root).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
src=${WAC_SRC:?set WAC_SRC to a wac checkout at the pinned commit}
rm -rf "$here/src/admit"
(cd "$root" && deno run -A "$src/packages/platform/build.ts" packages/reckon/cmd/web.wac -o "$here/src/admit" \
   --target browser --layout files --allow-net --allow-read --allow-write --allow-env)
if [ -n "${1:-}" ]; then
  out=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  rm -f "$out"
  (cd "$here/src" && zip -qr "$out" . -x '*.DS_Store')
  echo "$out: $(wc -c < "$out") bytes"
fi
