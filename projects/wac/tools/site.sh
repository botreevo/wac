#!/bin/sh
# Build wac's website into $1 — what the repository's Pages workflow publishes at the root.
#
# **The site is a wac program's output.** `site/wac/build.wac` writes every page as HTML into `site/dist/`, reading
# the figures it quotes from the tree as it is at this commit. The demos are built beside those pages, and the
# React app that still holds the playground goes into `site/dist/playground/`. **A demo that will not build fails
# this build** — and the workflow then keeps the last good site rather than publishing a broken one. Each step's
# reasons are in the history of `.github/workflows/pages.yml`, where these steps lived until the projects moved in.
#
# Needs deno and node 20+ on PATH, and the package cache filled (tools/fill-cache.sh).
set -eu
out=$(mkdir -p "${1:?usage: site.sh <out-dir>}" && cd "$1" && pwd)
cd "$(dirname "$0")/.."
sh tools/fill-cache.sh
deno run -A site/tools/syncDemos.ts                                  # builds .cache/wac-deno, then the demos
.cache/wac-deno run --allow-read --allow-write site/wac/build.wac site/dist
deno run -A --import-map deno.json site/tools/syncWacc.ts            # --import-map: issues/system/0146
(cd site && npm ci && deno run -A ../tools/syncBootstrap.ts && npx tsc -b && BASE_URL="${BASE_URL:-/wac/}" npx vite build)
deno test -A --unstable-sloppy-imports --no-check site/tools/site.test.ts
cp -R site/dist/. "$out/"
