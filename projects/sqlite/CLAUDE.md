# Notes for whoever works on this next

README.md says what this is and where it stands; read it first.

- **The real SQLite is the oracle.** When adding SQL, add a statement to a script in `test/corpus/`,
  run `python3 tools/corpus.py` to record what SQLite answers, and make `wac task test` agree. When
  changing the writer, run `wac task verify`.
- **wac is pinned by the `wac` you build**: this was written against wac `701028301`. When wac gets in the
  way, write it down in `docs/wac-asks.md` with a reproduction and work around it here.
- Comments explain *why*, in full sentences, as wac's own do.
- `const` in wac is deep and travels: a value read through a `const` reference cannot be stored in a
  plain one. Most structs here are passed without `const` for that reason.
