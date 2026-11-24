"""Checks dist/btree.db, which tools/btreefuzz.wac writes, with the real SQLite."""
import sqlite3, sys
db = sqlite3.connect("dist/btree.db")
ic = db.execute("PRAGMA integrity_check").fetchall()
want = open("dist/btree.txt").read().split("\n")
rows = [f"{a} 2" for (a,) in db.execute("SELECT a FROM t ORDER BY rowid")]
got = rows + [f"index {db.execute('SELECT count(*) FROM ix').fetchone()[0]}", f"free {db.execute('PRAGMA freelist_count').fetchone()[0]}", ""]
ok = ic == [("ok",)] and got == want
if not ok:
    print("integrity:", ic[:10])
    if got != want: print("contents differ:", len(got), len(want))
    sys.exit(1)
print("sqlite agrees")
