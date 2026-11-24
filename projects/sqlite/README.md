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

A database file is read a page at a time and written a page at a time, behind a rollback journal in
SQLite's format: opening a large file costs what reading its schema costs, and a commit writes the pages
it changed. This needs a wac whose std has `Files.openRandom` (wac master from `4085b2e9c`).

## Where it stands

**The file format, both ways.** It opens databases the real SQLite wrote — tables and indexes, interior
pages, overflow chains, rows shorter than their table after `ALTER TABLE ADD COLUMN`, integral values in
REAL columns stored as integers, `WITHOUT ROWID` tables, auto-vacuum pointer maps, UTF-16 text, and the
committed transactions in a write-ahead log beside the file — and writes files the real SQLite accepts: `PRAGMA integrity_check` is
`ok` on every one, and their contents compare equal row by row (`wac task verify`).

**The SQL is checked against SQLite itself.** `test/corpus/*.sql` are scripts; `tools/corpus.py` runs
each through Python's `sqlite3` and records what it answered, and `test/corpus_test.wac` runs the same
scripts here and compares, statement by statement. One of them is
[autonag](https://github.com/voltrevo/autonag)'s schema and every query its server makes, over generated
data.

| | |
| --- | --- |
| Statements | `SELECT` (row values, `LEFT`, `RIGHT`, `FULL` and `NATURAL` joins, `USING`, subqueries anywhere, correlated or not, `GROUP BY`/`HAVING`, `DISTINCT`, `UNION [ALL]`/`INTERSECT`/`EXCEPT`, `VALUES`, `LIMIT`/`OFFSET`), `WITH [RECURSIVE]`, `INSERT` and `UPDATE` (`OR IGNORE`/`REPLACE`/`FAIL`/`ABORT`/`ROLLBACK`, and each constraint's own `ON CONFLICT`; `ON CONFLICT … DO UPDATE`/`DO NOTHING`, `DEFAULT VALUES`, `INSERT … SELECT`), `UPDATE … FROM`, `DELETE`, `RETURNING` on all three, `CREATE TABLE`/`INDEX`/`VIEW`/`TRIGGER` (and `TEMP` ones), `CREATE TABLE … AS SELECT`, `DROP`, `ALTER TABLE` (`ADD COLUMN`, `RENAME TO`, `RENAME COLUMN`, `DROP COLUMN`), `BEGIN`/`COMMIT`/`ROLLBACK`, `SAVEPOINT`/`RELEASE`/`ROLLBACK TO`, `ANALYZE`, `REINDEX`, `VACUUM` |
| Typing | storage classes, column affinity, comparison affinity, `CAST`, integer overflow to real, SQLite's text for reals (`%!.15g`) |
| Schema | `INTEGER PRIMARY KEY` as the rowid, `AUTOINCREMENT` with `sqlite_sequence`, `PRIMARY KEY`/`UNIQUE` (with their automatic indexes), `NOT NULL`, `DEFAULT`, `CHECK`, foreign keys (enforced under `PRAGMA foreign_keys`, with `CASCADE`/`SET NULL`/`SET DEFAULT`/`RESTRICT` and `DEFERRABLE`), `COLLATE` (`BINARY`, `NOCASE`, `RTRIM`), generated columns (`VIRTUAL` and `STORED`), `STRICT` tables, `WITHOUT ROWID` tables, partial and expression indexes, views (and `INSTEAD OF` triggers on them), triggers (`BEFORE`/`AFTER`, `UPDATE OF`, `WHEN`, `RAISE`) |
| Functions | aggregates (`count sum total avg min max group_concat string_agg json_group_array json_group_object median percentile percentile_cont percentile_disc`, with `DISTINCT`, `FILTER` and `ORDER BY`), window functions (`row_number rank dense_rank percent_rank cume_dist ntile lag lead first_value last_value nth_value` and every aggregate, over `ROWS`/`RANGE`/`GROUPS` frames with `EXCLUDE`, named windows), the core scalar functions, `printf`/`format`, the date and time functions, the math functions, the JSON functions (JSON5 input, JSONB blobs and every `jsonb_` function) and `json_each`/`json_tree`, `->`, `->>`, `LIKE`/`GLOB` (with `ESCAPE`) |
| Pragmas | `user_version`, `application_id`, `schema_version`, `page_size`, `encoding`, `journal_mode` (WAL is kept), `auto_vacuum` (full and incremental files are written with their pointer maps; `VACUUM` applies a change, as in SQLite), `foreign_keys`, `table_info`/`table_xinfo`, `index_list`/`index_info`/`index_xinfo`, `foreign_key_list`, `foreign_key_check`, `collation_list`, `database_list`, all of them as `pragma_…()` tables too, and the connection's settings (`case_sensitive_like`, `ignore_check_constraints`, `defer_foreign_keys` taking effect; `cache_size`, `synchronous` and two dozen more read back as set) |
| Planning | an index (equality on leading columns, then a range) or the rowid narrows each source of a join; an index that delivers the `ORDER BY` lets a `LIMIT` stop early; a lone `min`/`max` reads one entry |

## Against SQLite's own wasm build

`node bench/run.mjs 20000` runs the same workloads through this library and through
[`@sqlite.org/sqlite-wasm`](https://www.npmjs.com/package/@sqlite.org/sqlite-wasm) 3.54.1 — SQLite itself,
compiled to WebAssembly — in the same Node, and checks a digest of every answer. The answers are the
same. Times in milliseconds, on 20,000 rows of autonag's events table (`bench/workloads.md`):

| workload | wac-sqlite | sqlite-wasm | ratio |
| --- | ---: | ---: | ---: |
| insert, one transaction | 323 | 253 | 1.27× |
| point lookup by text key ×10,000 | 126 | 79 | 1.59× |
| index range, ~50 rows ×1,000 | 130 | 248 | 0.52× |
| `MAX(seq)` through an index ×10,000 | 86 | 117 | 0.74× |
| `ORDER BY … DESC LIMIT 10` ×1,000 | 16 | 38 | 0.42× |
| `json_extract` full scan ×20 | 255 | 138 | 1.85× |
| `GROUP BY` ×20 | 298 | 145 | 2.05× |
| join + group ×20 | 316 | 44 | 7.2× |
| `LIKE '%…%'` full scan ×200 | 1551 | 871 | 1.78× |
| `UPDATE … json_set` ×2,000 | 100 | 17 | 6.0× |
| `DELETE` 20% | 143 | 7 | 20× |
| serialize the file | 4 | 3 | 1.08× |
| deserialize the file and scan it | 44 | 3 | 17× |
| **total** | **3392** | **1963** | **1.73×** |

Reading through indexes is where this wins. When everything was held decoded in memory the total was
0.98×; keeping the database on its pages, as SQLite does, costs a record decoded per row read (kept per
page for a while after) and a b-tree change per row written, and the deletes and the join pay most for
it. A full scan here decodes every column of every row, where SQLite decodes the ones a query reads; a
plain `count(*)` still decodes rows. Numbers move several percent run to run.

**And against SQLite's answers.** Beyond the hand-written corpus, seven fuzzers write random SQL and
record what SQLite 3.53 answers:

- `tools/fuzz.py`: expressions over mixed types — affinity, casts, arithmetic, every scalar function;
- `tools/fuzz2.py`: schemas, conflicts, upserts, joins, grouping, ordering, subqueries, changes;
- `tools/fuzz3.py`: window functions and frames, CTEs, RIGHT/FULL/NATURAL joins, row values, compound
  selects, JSON and `json_each`;
- `tools/fuzz4.py`: conflict clauses, foreign-key actions, CHECK, generated columns, STRICT, WITHOUT
  ROWID, partial and expression indexes, triggers, savepoints and transactions;
- `tools/fuzz5.py`: date and time functions with their modifiers, `strftime`, `printf` formats, string
  functions over non-ASCII text, numbers as text;
- `tools/fuzz6.py`: views over joins and aggregates, correlated subqueries everywhere, IN and EXISTS with
  NULLs, DISTINCT, collations and NULLS FIRST/LAST in ordering, LIMIT/OFFSET, compound selects;
- `tools/fuzz7.py`: ALTER TABLE renames and drops against the views, triggers, indexes and foreign keys
  that name what changes, comparing the whole of `sqlite_schema` (whose text SQLite rewrites) each time.

At least the first 40 seeds of each agree statement for statement (90 of the first two, 80 of the
fifth, 100 of the seventh); seed 1 of each is in `test/corpus`, and `sh tools/fuzzdiffN.sh <seed>` shows where a seed
disagrees. Where SQLite's answer is its planner's choice rather than the SQL's meaning (which row a
group shows, the order of rows a query does not order), the fuzzers ask only questions with one
answer. Reals become text through a port of SQLite's own decimal conversion (`src/fp.wac`), so
`CAST(1.0/3 AS TEXT)` is `0.33333333333333332` here too.

## How it works, and what that costs

**The database is its pages.** Every table is a table b-tree and every index an index b-tree, on a pager
(`src/pager.wac`, `src/btree.wac`), laid out exactly as SQLite lays them out. Statements read rows through
cursors and change them where they lie: a cell goes into a page's free space or comes out as a free
block, a page that overflows splits, a page a deletion empties goes and its neighbour takes the
parent's divider. Opening a database reads its header and `sqlite_schema` and nothing else.

**Every change can be undone.** The first time a transaction (or a statement, or a `SAVEPOINT`) changes a
page, the page as it was is kept; a rollback puts those back. A commit writes `sqlite_schema` again if the
schema changed, and the header, onto page 1, and then:

- **A file (`SqliteFile`)** writes a rollback journal holding the old contents of every page the commit
  changes, syncs it, writes the changed pages over the file, syncs that, and deletes the journal — the
  commit point, as in SQLite's default journal mode. The journal is SQLite's format, so after a crash
  SQLite plays it back, and so does this library when it opens the file (`test/paging_test.wac`, and
  `tools/journal_check.py` with the real SQLite).
- **A memory database** (`Connection.memory()`, `openBytes`) keeps its pages in memory, and `image()`
  is those pages.

So:

- **Memory** is what is in use, not the database: a bounded cache of pages (2,000 by default) and of
  decoded rows, plus the pages a transaction has changed until it commits. A 2.4 MB file is read and
  changed through a 20-page cache in the tests. Large transactions hold their changed pages (and the
  old contents) until the commit.
- **Two things are still held in memory whole**: `TEMP` tables, and `WITHOUT ROWID` tables (the engine
  works with rowids, so such a table is kept as a rowid table in memory, numbered as read, and written
  back to its b-trees in the file at a commit after it changed).
- **Some commits write a whole new image**: `VACUUM`, and every commit to an auto-vacuum database, whose
  pointer map is not kept up page by page. Those build the image in memory and rename it over the file.
- **Other processes' commits are seen, but no locks are taken.** Each statement outside a transaction
  first rereads the header's change counter and, if another connection has committed, reads the database
  afresh (so a server sees what an admin tool beside it wrote). SQLite's locks are not taken: two programs
  writing at the same moment would lose one side's changes, and one reading during a commit could see
  half of it.
- **WAL mode is kept, and a `-wal` beside the file is read**: its committed pages are laid over the
  file's on opening, and checkpointed into it (then the log and `-shm` removed) before the first write.
  That assumes no other connection is using the database meanwhile.

## Not yet

Virtual tables (FTS5, R*Tree), `ATTACH`, and `EXPLAIN`. JSONB that SQLite would write with its JSON5
or raw-text element types (`jsonb()` of JSON5 text, `jsonb_set()` with a text value) is written with the
plain ones here: the same JSON, other bytes. A `TEMP` object may not share a name
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
    wac run --allow-read --allow-write tools/btreefuzz.wac -- 7 5000 && python3 tools/btreecheck.py   # the b-trees alone
    sh tools/fuzzdiff.sh 7; sh tools/fuzzdiff2.sh 7   # a fuzz seed against SQLite
    python3 tools/corpus.py                      # regenerate test/corpus/*.out
    wac run --allow-read --allow-write tools/sql.wac -- my.db script.sql   # a small shell

| | |
| --- | --- |
| `src/value.wac`, `record.wac`, `bytes.wac` | values, the record format, varints |
| `src/pager.wac`, `btree.wac` | pages read when wanted and undone on rollback; b-trees changed in place |
| `src/database.wac`, `reader.wac`, `writer.wac` | the schema; opening and committing; a whole image for VACUUM |
| `src/lexer.wac`, `parser.wac`, `ast.wac` | SQL text into statements |
| `src/schema.wac` | tables, indexes and rows over their b-trees |
| `src/query.wac`, `plan.wac`, `ops.wac`, `functions.wac`, `json.wac` | binding, evaluation, SELECT |
| `src/engine.wac` | `Connection`: changes, constraints, transactions |
| `src/file.wac` | `SqliteFile`: pages read from a file and committed behind a rollback journal |
