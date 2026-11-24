#!/bin/sh
# Build the desktop's site into $1 — what the repository's Pages workflow publishes at /desktop/. `wac` on PATH is
# the one wac.lock pins, and the package cache is filled; tools/ci-build.sh does both, from nothing.
set -eu
out=$(mkdir -p "${1:?usage: pages.sh <out-dir>}" && cd "$1" && pwd)
cd "$(dirname "$0")/.."
sh tools/ci-build.sh
cp -R dist/. "$out/"
