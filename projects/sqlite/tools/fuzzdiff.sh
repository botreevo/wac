#!/bin/sh
# The first statements where this library and SQLite disagree, for one fuzz seed:
#     sh tools/fuzzdiff.sh 12
# Leaves test/corpus/fuzz.sql at that seed; `python3 tools/fuzz.py && python3 tools/corpus.py` restores it.
set -eu
python3 tools/fuzz.py "$1" "${2:-400}"
python3 tools/corpus.py > /dev/null
wac run --allow-read tools/corpus_run.wac -- test/corpus/fuzz.sql > dist/fuzz.got 2> dist/fuzz.err || true
if [ ! -s dist/fuzz.got ]; then echo "trapped:"; tail -3 dist/fuzz.err; exit 0; fi
python3 - <<'PY'
def blocks(path):
    out, cur = [], None
    for line in open(path).read().splitlines():
        if line.startswith("> "):
            cur = [line, []]; out.append(cur)
        elif cur: cur[1].append(line)
    return out
got, want = blocks("dist/fuzz.got"), blocks("test/corpus/fuzz.out")
shown = 0
for g, w in zip(got, want):
    if g != w:
        print(w[0][:400]); print("   sqlite:", w[1][:6]); print("   ours:  ", g[1][:6]); shown += 1
        if shown >= 4: break
PY
