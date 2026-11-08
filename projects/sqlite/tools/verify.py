"""Asks the real SQLite about a file this library wrote: integrity_check, then a dump compared with
the dump of the file it was made from.

    python3 tools/verify.py original.db written.db
"""
import sqlite3, sys

def dump(path):
    con = sqlite3.connect(path)
    out = []
    for (name, kind, sql) in con.execute("SELECT name, type, sql FROM sqlite_schema ORDER BY rowid"):
        out.append((kind, name, sql))
        if kind == "table":
            out.extend(con.execute(f'SELECT rowid, * FROM "{name}" ORDER BY rowid').fetchall())
        elif kind == "index":
            # Every index lookup path, forced through the index.
            out.append(con.execute(f'SELECT count(*) FROM "{con.execute("SELECT tbl_name FROM sqlite_schema WHERE name = ?", (name,)).fetchone()[0]}" INDEXED BY "{name}"').fetchone() if not name.startswith("sqlite_autoindex") else ("auto",))
    con.close()
    return out

orig, written = sys.argv[1], sys.argv[2]
con = sqlite3.connect(written)
res = con.execute("PRAGMA integrity_check").fetchall()
con.close()
ok = res == [("ok",)]
if not ok:
    print(written + ": integrity_check:")
    for r in res[:20]: print("  ", r[0])
a, b = dump(orig), dump(written)
if a != b:
    ok = False
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            print(f"{written}: first difference at item {i}: {x!r} vs {y!r}")
            break
    else:
        print(f"{written}: {len(a)} items vs {len(b)}")
print(("ok   " if ok else "FAIL ") + written)
sys.exit(0 if ok else 1)
