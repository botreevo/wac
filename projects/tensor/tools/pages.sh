#!/bin/sh
# Build tensor's site into $1 — what the repository's Pages workflow publishes at /tensor/. The site is
# tools/site.sh's: the landing page, the draw-a-digit demo and the CPU-vs-GPU benchmark, linked relatively, so it
# works under any path. `wac` on PATH is the workflow's.
set -eu
out=$(mkdir -p "${1:?usage: pages.sh <out-dir>}" && cd "$1" && pwd)
cd "$(dirname "$0")/.."
sh tools/site.sh
cp -R dist/site/. "$out/"
