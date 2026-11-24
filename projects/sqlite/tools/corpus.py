"""Runs each test/corpus/*.sql through the real SQLite and writes what it answers to a .out beside it.

Each statement's result is one block: its rows, values joined by '|', or the word `error` when SQLite
refused it (messages differ between implementations; whether it failed does not). The wac side
(test/corpus_test.wac) runs the same files and must produce the same blocks.

    python3 tools/corpus.py
"""
import glob, sqlite3

def render(con, v):
    if v is None: return "NULL"
    if isinstance(v, int): return str(v)
    if isinstance(v, float):
        # SQLite's own text for a real, which is what this library prints.
        return con.execute("SELECT printf('%!.15g', ?)", (v,)).fetchone()[0]
    if isinstance(v, bytes): return "X'" + v.hex().upper() + "'"
    return "'" + v.replace("'", "''") + "'"

def statements(text):
    buf = ""
    for line in text.splitlines(keepends=True):
        if not buf.strip() and line.strip().startswith("--"):
            continue
        buf += line
        if sqlite3.complete_statement(buf):
            yield buf.strip()
            buf = ""
    if buf.strip():
        yield buf.strip()

if __name__ == "__main__":
    for path in sorted(glob.glob("test/corpus/*.sql")):
        con = sqlite3.connect(":memory:", isolation_level=None)
        out = []
        for st in statements(open(path).read()):
            out.append("> " + st.splitlines()[0])
            try:
                cur = con.execute(st)
                for row in cur.fetchall():
                    out.append("|".join(render(con, v) for v in row))
            except sqlite3.Error as e:
                out.append("error")
        con.close()
        with open(path[:-4] + ".out", "w") as f:
            f.write("\n".join(out) + "\n")
        print("wrote", path[:-4] + ".out")
