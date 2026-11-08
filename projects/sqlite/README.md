# wac-sqlite

SQLite in [wac](https://github.com/voltrevo/wac): it reads and writes real SQLite database files and
runs the SQL that applications use, written in wac with nothing borrowed from the C library but the file
format and the language.

```wac
import { Connection, Rows, Value } from "sqlite";

Connection c = Connection.memory();
c.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT UNIQUE)").unwrap();
c.execute("INSERT INTO t (name) VALUES (?)", [Value.Text("alice")]).unwrap();
Rows r = c.execute("SELECT id, name FROM t WHERE name = ?", [Value.Text("alice")]).unwrap();
// r.columns is ["id", "name"]; r.rows.get(0) is [Int(1), Text("alice")]
```

A file on disk:

```wac
import { SqliteFile, Value } from "sqlite";

SqliteFile db = SqliteFile.open(sys.files(), "data/app.db").unwrap();   // created at the first commit
db.execute("INSERT INTO events (id, seq) VALUES (?, ?)", [Value.Text("e1"), Value.Int(1)]).unwrap();
```

## Where it stands

**The file format, both ways.** It opens databases the real SQLite wrote — tables and indexes, interior
pages, overflow chains, rows shorter than their table after `ALTER TABLE ADD COLUMN`, integral values in
REAL columns stored as integers — and writes files the real SQLite accepts: `PRAGMA integrity_check` is
`ok` on every one, and their contents compare equal row by row (`wac task verify`).

**The SQL is checked against SQLite itself.** `test/corpus/*.sql` are scripts; `tools/corpus.py` runs
each through Python's `sqlite3` and records what it answered, and `test/corpus_test.wac` runs the same
scripts here and compares, statement by statement. One of them is
[autonag](https://github.com/voltrevo/autonag)'s schema and every query its server makes, over generated
data.

| | |
| --- | --- |
| Statements | `SELECT` (joins, `LEFT JOIN`, subqueries in `FROM` and expressions, correlated or not, `GROUP BY`/`HAVING`, `DISTINCT`, `UNION [ALL]`/`INTERSECT`/`EXCEPT`, `VALUES`, `LIMIT`/`OFFSET`), `INSERT` (`OR IGNORE`/`OR REPLACE`, `ON CONFLICT … DO UPDATE`/`DO NOTHING`, `DEFAULT VALUES`, `INSERT … SELECT`), `UPDATE`, `DELETE`, `RETURNING` on all three, `CREATE TABLE`/`INDEX` (`IF NOT EXISTS`, `UNIQUE`), `DROP`, `ALTER TABLE ADD COLUMN`, `BEGIN`/`COMMIT`/`ROLLBACK` |
| Typing | storage classes, column affinity, comparison affinity, `CAST`, integer overflow to real, SQLite's text for reals (`%!.15g`) |
| Constraints | `INTEGER PRIMARY KEY` as the rowid, `AUTOINCREMENT` with `sqlite_sequence`, `PRIMARY KEY`/`UNIQUE` (with their automatic indexes), `NOT NULL`, `DEFAULT` |
| Functions | `count sum total avg min max group_concat`, `coalesce ifnull nullif iif length lower upper substr instr replace trim ltrim rtrim abs round sign hex unhex quote typeof unicode char zeroblob random randomblob changes last_insert_rowid`, `json json_extract json_set json_insert json_replace json_remove json_object json_array json_type json_valid json_array_length`, `->`, `->>`, `LIKE`/`GLOB` (with `ESCAPE`) |
| Pragmas | `user_version`, `page_size`, `table_info`, and the ones an application sets and does not read back (`journal_mode`, `foreign_keys`, `busy_timeout`, …) |
| Planning | an index (equality on leading columns, then a range) or the rowid narrows each source of a join; an index that delivers the `ORDER BY` lets a `LIMIT` stop early; a lone `min`/`max` reads one entry |

## How it works, and what that costs

The whole database lives in memory: rows in rowid order and every index as a sorted list. Opening a file
reads it whole; **each commit writes it whole**, every b-tree built bottom-up and packed, to a temporary
file that is then renamed over the original. That is how wac's std reads and writes files today (whole
files), it is VACUUM's output every time, and it keeps the writer to one path that is easy to check.

So:

- **A commit costs time proportional to the database**: about 40 ms for 20,000 rows and 3 MB
  (`wac run tools/bench.wac -- 20000`). Batch writes into a transaction where it matters.
- **One writer.** SQLite's locks are not taken. Readers, the real SQLite included, are safe — they see
  the old file or the new one.
- **A database with a `-wal` or hot `-journal` beside it is refused**: those hold changes the main file
  does not. Checkpoint with SQLite first (`PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE`).
- Memory is the whole database, decoded.

## Not yet

Foreign keys are parsed, kept in the schema and **not enforced** — SQLite's default too, but an
application that turns them on and relies on `ON DELETE CASCADE` (autonag does) needs them. Also absent:
views, triggers, `WITH`, window functions, `WITHOUT ROWID` tables, partial and expression indexes,
collations other than `BINARY`, `printf`/`format`, the date and time functions (only `CURRENT_TIMESTAMP`,
`CURRENT_DATE` and `CURRENT_TIME`, from a clock the caller sets), `ALTER TABLE RENAME`, savepoints, and
text encodings other than UTF-8. Each is refused with an `unsupported` error rather than half done.

## Using it from another project

```json5
// wac.json5
{ imports: { sqlite: { git: 'https://git.voltrevo.com/wac-sqlite.git', ref: 'main' } } }
```

`wac update` cannot fetch from git.voltrevo.com (it answers wac's fetcher 401). Pin the commit in
`wac.lock` and fill the cache with `git` instead, as [wacuum](https://git.voltrevo.com/wacuum.git)'s
`tools/deps.wac` does:

```json
{ "imports": { "sqlite": { "git": "https://git.voltrevo.com/wac-sqlite.git", "ref": "main", "commit": "<40 hex>" } } }
```

## Working on it

    wac task test        # every unit and corpus test (reads test/data and test/corpus)
    wac task verify      # files written here, checked by the real SQLite (needs python3)
    wac task fixtures    # regenerate test/data with the real SQLite
    python3 tools/corpus.py                      # regenerate test/corpus/*.out
    wac run --allow-read --allow-write tools/sql.wac -- my.db script.sql   # a small shell

| | |
| --- | --- |
| `src/value.wac`, `record.wac`, `bytes.wac` | values, the record format, varints |
| `src/reader.wac`, `writer.wac`, `database.wac` | the file: reading b-trees, building them, the schema |
| `src/lexer.wac`, `parser.wac`, `ast.wac` | SQL text into statements |
| `src/schema.wac` | tables, indexes and rows in memory |
| `src/query.wac`, `plan.wac`, `ops.wac`, `functions.wac`, `json.wac` | binding, evaluation, SELECT |
| `src/engine.wac` | `Connection`: changes, constraints, transactions |
| `src/file.wac` | `SqliteFile`: a connection backed by a file |
