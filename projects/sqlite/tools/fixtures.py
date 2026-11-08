"""Writes the test databases in test/data with the real SQLite, and a dump of what each holds.

Run from the repository root: python3 tools/fixtures.py. The files are committed, so the tests need
neither Python nor SQLite; this is how they were made, and how to make them again.
"""
import os, sqlite3, random

def render(v):
    if v is None: return "NULL"
    if isinstance(v, int): return str(v)
    if isinstance(v, float): return repr(v)
    if isinstance(v, bytes): return "X'" + v.hex().upper() + "'"
    return "'" + v.replace("'", "''") + "'"

def dump(path):
    con = sqlite3.connect(path)
    out = []
    for name, kind in con.execute("SELECT name, type FROM sqlite_schema WHERE type = 'table' ORDER BY rowid"):
        out.append("table " + name)
        try:
            rows = con.execute(f'SELECT rowid, * FROM "{name}" ORDER BY rowid').fetchall()
        except sqlite3.OperationalError:
            rows = con.execute(f'SELECT * FROM "{name}"').fetchall()   # WITHOUT ROWID: in key order
        for row in rows:
            out.append("|".join(render(v) for v in row))
    con.close()
    with open(path[:-3] + ".txt", "w") as f:
        f.write("\n".join(out) + "\n")

def make(path, page_size, build, vacuum=True):
    if os.path.exists(path): os.remove(path)
    con = sqlite3.connect(path)
    con.execute(f"PRAGMA page_size = {page_size}")
    build(con)
    con.commit()
    if vacuum: con.execute("VACUUM")
    con.close()
    dump(path)

def small(con):
    con.execute("CREATE TABLE t (a, b TEXT, c REAL, d BLOB)")
    con.executemany("INSERT INTO t VALUES (?, ?, ?, ?)", [
        (None, "x", 1.5, b"\x00\x01"),
        (5, "ab", 2.0, None),
        (-300, "héllo", -0.25, b""),
        (9223372036854775807, "", 0.0, b"\xff"),
        (1, "it's", None, None),
    ])

def big(con):
    rnd = random.Random(7)
    con.execute("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT UNIQUE, age INTEGER, notes TEXT)")
    con.execute("CREATE INDEX people_age ON people (age)")
    rows = []
    for i in range(1, 3001):
        notes = None
        if i % 97 == 0: notes = "long " * rnd.randint(200, 3000)   # past one page: overflow chains
        elif i % 3 == 0: notes = "n%d" % rnd.randint(0, 10**9)
        rows.append((i * 3, "person-%05d" % rnd.randint(0, 10**5) + "-%d" % i, rnd.randint(0, 99), notes))
    con.executemany("INSERT INTO people VALUES (?, ?, ?, ?)", rows)
    con.execute("CREATE TABLE kv (k TEXT PRIMARY KEY, v)")
    con.executemany("INSERT INTO kv VALUES (?, ?)", [("k%04d" % i, i * i) for i in range(500)])

def without_rowid(con):
    rnd = random.Random(11)
    con.execute("CREATE TABLE big (k TEXT, n INT, pad, PRIMARY KEY (n DESC, k)) WITHOUT ROWID")
    con.execute("CREATE INDEX big_pad ON big (pad)")
    con.execute("CREATE TABLE names (name TEXT PRIMARY KEY COLLATE NOCASE, v UNIQUE) WITHOUT ROWID")
    con.executemany("INSERT INTO big VALUES (?, ?, ?)",
                    [("k%d" % i, i % 50, "p" * rnd.randint(0, 250)) for i in range(1, 601)])
    con.executemany("INSERT INTO names VALUES (?, ?)", [("Name%d" % i, i * 7) for i in range(300)])
    # A column added later: older records are short, and read with its default.
    con.execute("ALTER TABLE names ADD COLUMN extra DEFAULT 'd'")
    con.execute("INSERT INTO names VALUES ('zz', -1, 'x')")

os.makedirs("test/data", exist_ok=True)
make("test/data/small.db", 4096, small)
make("test/data/big.db", 1024, big)
make("test/data/big4k.db", 4096, big)
# Not vacuumed, which would rewrite the short records.
make("test/data/without_rowid.db", 1024, without_rowid, vacuum=False)
