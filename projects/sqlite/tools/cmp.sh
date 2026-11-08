#!/bin/sh
# One script through both: `sh tools/cmp.sh file.sql` prints SQLite's answers, then this library's.
python3 - "$1" <<'PY'
import sys; sys.path.insert(0, "tools")
import sqlite3
from corpus import statements, render
con = sqlite3.connect(":memory:", isolation_level=None)
for st in statements(open(sys.argv[1]).read()):
    print("> " + st.splitlines()[0][:100])
    try:
        for row in con.execute(st).fetchall(): print("|".join(render(con, v) for v in row))
    except sqlite3.Error as e: print("error", e)
PY
echo "======== wac-sqlite"
wac run --allow-read tools/corpus_run.wac -- "$1" | cut -c1-100
