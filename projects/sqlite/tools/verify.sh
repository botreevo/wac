#!/bin/sh
# Files this library writes, checked by the real SQLite (Python's sqlite3): integrity_check, and a
# row-by-row comparison with what SQLite itself produces from the same input.
#
#   - each fixture in test/data, read and written back;
#   - each corpus script in test/corpus, run into a file here and by SQLite into another;
#   - the files test/paging_test.wac leaves (run `wac task test` first), and the journal of a commit it
#     stopped before its commit point, which SQLite must play back.
set -eu
mkdir -p dist
status=0
for f in test/data/*.db; do
  # Work from a copy: SQLite reading a database checkpoints its log, which would change the fixture.
  name="$(basename "$f" .db)"
  rm -f "dist/$name.orig.db" "dist/$name.orig.db-wal" "dist/$name.orig.db-shm"
  cp "$f" "dist/$name.orig.db"
  if [ -f "$f-wal" ]; then cp "$f-wal" "dist/$name.orig.db-wal"; fi
  out="dist/$name.db"
  wac run --allow-read --allow-write tools/rewrite.wac -- "dist/$name.orig.db" "$out"
  python3 tools/verify.py "dist/$name.orig.db" "$out" || status=1
done
for f in test/corpus/*.sql; do
  name="$(basename "$f" .sql)"
  rm -f "dist/$name.db" "dist/$name.ref.db"
  wac run --allow-read --allow-write tools/sql.wac -- "dist/$name.db" "$f" > /dev/null || true
  python3 tools/script_db.py "$f" "dist/$name.ref.db"
  python3 tools/verify.py "dist/$name.ref.db" "dist/$name.db" || status=1
done
python3 tools/journal_check.py || status=1
exit $status
