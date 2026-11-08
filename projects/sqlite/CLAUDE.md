# Notes for whoever works on this next

README.md says what this is and where it stands; read it first.

- **The real SQLite is the oracle.** When adding SQL, add a statement to a script in `test/corpus/`,
  run `python3 tools/corpus.py` to record what SQLite answers, and make `wac task test` agree. When
  changing the writer, run `wac task verify`.
- **Fuzz what you change.** `sh tools/fuzzdiffN.sh <seed>` (N empty or 2–6, see README) regenerates a
  fuzz script for that seed, records SQLite's answers and shows the first disagreements; run a span of
  seeds after a change to the area it covers, then `python3 tools/fuzzN.py 1 && python3 tools/corpus.py`
  to put seed 1 back. A disagreement is SQLite's meaning or its planner's choice: fix the first, and
  make the fuzzer stop asking the second (which row a group shows, row order nobody asked for).
- **Python's sqlite3 cannot decode every answer**: text SQLite builds from surrogates, or cuts mid
  character (a byte precision in printf), comes back as an error in the `.out` files. Keep the fuzzers
  and scripts away from those rather than imitating the error.
- **wac is pinned by the `wac` you build**: this needs `Files.openRandom`, on wac's master from
  `4085b2e9c` (git.voltrevo.com/wac); build wac at or after it (`./bootstrap.sh --host nodejs -o <path>`). When wac gets in the way, write it down in
  `docs/wac-asks.md` with a reproduction and work around it here.
- **The database is its pages.** Tables and indexes are b-trees on a pager (src/pager.wac,
  src/btree.wac); `tools/btreefuzz.wac` + `tools/btreecheck.py` check the b-trees alone, and
  `test/paging_test.wac` + `tools/journal_check.py` (run by verify.sh) the file layer and its journal.
- Comments explain *why*, in full sentences, as wac's own do.
- `const` in wac is deep and travels: a value read through a `const` reference cannot be stored in a
  plain one. Most structs here are passed without `const` for that reason.
