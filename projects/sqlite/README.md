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
| Statements | `SELECT` (inner, `LEFT`, `RIGHT`, `FULL` and `NATURAL` joins, `USING`, subqueries anywhere, correlated or not, `GROUP BY`/`HAVING`, `DISTINCT`, `UNION [ALL]`/`INTERSECT`/`EXCEPT`, `VALUES`, `LIMIT`/`OFFSET`), `WITH [RECURSIVE]`, `INSERT` and `UPDATE` (`OR IGNORE`/`REPLACE`/`FAIL`/`ABORT`/`ROLLBACK`, and each constraint's own `ON CONFLICT`; `ON CONFLICT … DO UPDATE`/`DO NOTHING`, `DEFAULT VALUES`, `INSERT … SELECT`), `DELETE`, `RETURNING` on all three, `CREATE TABLE`/`INDEX`/`VIEW`/`TRIGGER`, `DROP`, `ALTER TABLE` (`ADD COLUMN`, `RENAME TO`, `RENAME COLUMN`, `DROP COLUMN`), `BEGIN`/`COMMIT`/`ROLLBACK`, `SAVEPOINT`/`RELEASE`/`ROLLBACK TO` |
| Typing | storage classes, column affinity, comparison affinity, `CAST`, integer overflow to real, SQLite's text for reals (`%!.15g`) |
| Schema | `INTEGER PRIMARY KEY` as the rowid, `AUTOINCREMENT` with `sqlite_sequence`, `PRIMARY KEY`/`UNIQUE` (with their automatic indexes), `NOT NULL`, `DEFAULT`, `CHECK`, foreign keys (enforced under `PRAGMA foreign_keys`, with `CASCADE`/`SET NULL`/`SET DEFAULT`/`RESTRICT` and `DEFERRABLE`), `COLLATE` (`BINARY`, `NOCASE`, `RTRIM`), generated columns (`VIRTUAL` and `STORED`), `STRICT` tables, `WITHOUT ROWID` tables, partial and expression indexes, views (and `INSTEAD OF` triggers on them), triggers (`BEFORE`/`AFTER`, `UPDATE OF`, `WHEN`, `RAISE`) |
| Functions | aggregates (`count sum total avg min max group_concat string_agg json_group_array json_group_object`, with `DISTINCT`, `FILTER` and `ORDER BY`), window functions (`row_number rank dense_rank percent_rank cume_dist ntile lag lead first_value last_value nth_value` and every aggregate, over `ROWS`/`RANGE`/`GROUPS` frames with `EXCLUDE`, named windows), the core scalar functions, `printf`/`format`, the date and time functions, the math functions, the JSON functions and `json_each`/`json_tree`, `->`, `->>`, `LIKE`/`GLOB` (with `ESCAPE`) |
| Pragmas | `user_version`, `page_size`, `table_info`, `journal_mode` (WAL is kept), `auto_vacuum` (full and incremental files are written with their pointer maps; `VACUUM` applies a change, as in SQLite), and the ones an application sets and does not read back (`journal_mode`, `foreign_keys`, `busy_timeout`, …) |
| Planning | an index (equality on leading columns, then a range) or the rowid narrows each source of a join; an index that delivers the `ORDER BY` lets a `LIMIT` stop early; a lone `min`/`max` reads one entry |

## Against SQLite's own wasm build

`node bench/run.mjs 20000` runs the same workloads through this library and through
[`@sqlite.org/sqlite-wasm`](https://www.npmjs.com/package/@sqlite.org/sqlite-wasm) 3.54.1 — SQLite itself,
compiled to WebAssembly — in the same Node, and checks a digest of every answer. The answers are the
same. Times in milliseconds, on 20,000 rows of autonag's events table (`bench/workloads.md`):

| workload | wac-sqlite | sqlite-wasm | ratio |
| --- | ---: | ---: | ---: |
| insert, one transaction | 222 | 225 | 0.99× |
| point lookup by text key ×10,000 | 76 | 69 | 1.09× |
| index range, ~50 rows ×1,000 | 65 | 202 | 0.32× |
| `MAX(seq)` through an index ×10,000 | 53 | 111 | 0.48× |
| `ORDER BY … DESC LIMIT 10` ×1,000 | 11 | 33 | 0.34× |
| `json_extract` full scan ×20 | 116 | 137 | 0.85× |
| `GROUP BY` ×20 | 101 | 143 | 0.71× |
| join + group ×20 | 73 | 42 | 1.72× |
| `LIKE '%…%'` full scan ×200 | 957 | 840 | 1.14× |
| `UPDATE … json_set` ×2,000 | 41 | 15 | 2.73× |
| `DELETE` 20% | 14 | 7 | 1.96× |
| serialize the file | 29 | 3 | 10× |
| deserialize the file | 35 | 2 | 15× |
| **total** | **1792** | **1829** | **0.98×** |

Reading through indexes is where this wins; producing and loading a whole file image is where it loses,
since SQLite's image is its pages already and this one is built from rows (an unchanged row's record is
kept, so a commit after a small change costs less than the first). Numbers move a few percent run to run.

**And against SQLite's answers.** Beyond the hand-written corpus, two fuzzers write random SQL and
record what SQLite 3.53 answers: `tools/fuzz.py` (expressions over mixed types — affinity, casts,
arithmetic, every scalar function) and `tools/fuzz2.py` (schemas, conflicts, upserts, joins, grouping,
ordering, subqueries, changes). Seeds 1–60 of each agree statement for statement; seed 1 of each is in
`test/corpus`. `sh tools/fuzzdiff.sh <seed>` shows any disagreement. Reals become text through a port
of SQLite's own decimal conversion (`src/fp.wac`), so `CAST(1.0/3 AS TEXT)` is `0.33333333333333332`
here too.

## How it works, and what that costs

The whole database lives in memory: rows in rowid order and every index as a sorted list. Opening a file
reads it whole; **each commit writes it whole**, every b-tree built bottom-up and packed, to a temporary
file that is then renamed over the original. That is how wac's std reads and writes files today (whole
files), it is VACUUM's output every time, and it keeps the writer to one path that is easy to check.

So:

- **A commit costs time proportional to the database**: about 15–30 ms for 20,000 rows and 3 MB.
  Batch writes into a transaction where it matters.
- **One writer.** SQLite's locks are not taken. Readers, the real SQLite included, are safe — they see
  the old file or the new one.
- **WAL mode is kept, and a `-wal` beside the file is read**: its committed transactions are laid over
  the file on opening, and checkpointed into it (then the log and `-shm` removed) before the first
  write. That assumes no other connection is using the database meanwhile. A hot `-journal` (a crashed
  rollback-mode writer's) is refused: open the database with SQLite once to recover it.
- Memory is the whole database, decoded.

## Not yet

Virtual tables (FTS5, R*Tree), `ATTACH`, JSONB, and `EXPLAIN`. A `TEMP` object may not share a name
with one in the main schema, as SQLite allows. UTF-16 databases are read and written (their indexes in SQLite's order), but
text compares in code point order in queries, where SQLite compares UTF-16 bytes, so `ORDER BY` and
ranges over non-ASCII text can differ there. Partial and expression indexes are kept and
enforced, but the planner does not yet read through them. Each missing feature is refused with an error
rather than half done.

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
    node bench/run.mjs 20000                     # the benchmark (cd bench && npm install, once)
    sh tools/fuzzdiff.sh 7; sh tools/fuzzdiff2.sh 7   # a fuzz seed against SQLite
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
