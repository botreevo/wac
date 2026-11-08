#!/bin/sh
# Each fixture, read and written back by this library, then checked by the real SQLite: integrity_check
# and a row-by-row comparison with the original.
set -eu
mkdir -p dist
status=0
for f in test/data/*.db; do
  out="dist/$(basename "$f")"
  wac run --allow-read --allow-write tools/rewrite.wac -- "$f" "$out"
  python3 tools/verify.py "$f" "$out" || status=1
done
exit $status
