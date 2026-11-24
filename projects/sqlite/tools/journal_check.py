"""After test/paging_test.wac: SQLite itself opens the database whose commit was stopped before its
journal was deleted, plays the journal back, and finds the database as it was before that commit."""
import sqlite3, os, sys
p = "dist/paging_crash_sqlite.db"
if not os.path.exists(p + "-journal"):
    print("no journal left to recover"); sys.exit(1)
con = sqlite3.connect(p)
rows = con.execute("SELECT s FROM t ORDER BY id").fetchall()
ok = con.execute("PRAGMA integrity_check").fetchone()[0]
con.close()
if rows != [("kept",)] or ok != "ok" or os.path.exists(p + "-journal"):
    print("after recovery:", rows, ok, os.path.exists(p + "-journal")); sys.exit(1)
for name in ["dist/paging_big.db", "dist/paging_crash.db", "dist/paging_wal.db"]:
    c = sqlite3.connect(name)
    r = c.execute("PRAGMA integrity_check").fetchone()[0]
    if r != "ok": print(name, r); sys.exit(1)
print("sqlite recovers the journal; the paged files check ok")
