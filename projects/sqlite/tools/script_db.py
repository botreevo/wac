"""Runs a SQL script into a database file with the real SQLite, carrying on past statements it refuses,
the way tools/sql.wac does: `python3 tools/script_db.py script.sql out.db`."""
import sqlite3, sys
sys.path.insert(0, "tools")
from corpus import statements
import os
if os.path.exists(sys.argv[2]): os.remove(sys.argv[2])
con = sqlite3.connect(sys.argv[2], isolation_level=None)
for st in statements(open(sys.argv[1]).read()):
    try: con.execute(st).fetchall()
    except sqlite3.Error: pass
con.close()
