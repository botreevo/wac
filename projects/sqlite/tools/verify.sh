#!/bin/sh
# Files this library writes, checked by the real SQLite (Python's sqlite3): integrity_check, and a
# row-by-row comparison with what SQLite itself produces from the same input.
#
#   - each fixture in test/data, read and written back;
#   - each corpus script in test/corpus, run into a file here and by SQLite into another.
set -eu
mkdir -p dist
status=0
for f in test/data/*.db; do
  out="dist/$(basename "$f")"
  wac run --allow-read --allow-write tools/rewrite.wac -- "$f" "$out"
  python3 tools/verify.py "$f" "$out" || status=1
done
for f in test/corpus/*.sql; do
  name="$(basename "$f" .sql)"
  rm -f "dist/$name.db" "dist/$name.ref.db"
  wac run --allow-read --allow-write tools/sql.wac -- "dist/$name.db" "$f" > /dev/null || true
  python3 tools/script_db.py "$f" "dist/$name.ref.db"
  python3 tools/verify.py "dist/$name.ref.db" "dist/$name.db" || status=1
done
exit $status
