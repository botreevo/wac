#!/bin/sh
# As fuzzdiff.sh, for tools/fuzz7.py.
set -eu
python3 tools/fuzz7.py "$1" "${2:-60}"
python3 tools/corpus.py > /dev/null
wac run --allow-read tools/corpus_run.wac -- test/corpus/fuzz7.sql > dist/fuzz.got 2> dist/fuzz.err || true
if [ ! -s dist/fuzz.got ]; then echo "trapped:"; tail -3 dist/fuzz.err; exit 0; fi
python3 - <<'PY'
def blocks(path):
    out, cur = [], None
    for line in open(path).read().splitlines():
        if line.startswith("> "):
            cur = [line, []]; out.append(cur)
        elif cur: cur[1].append(line)
    return out
got, want = blocks("dist/fuzz.got"), blocks("test/corpus/fuzz7.out")
shown = 0
for g, w in zip(got, want):
    if g != w:
        print(w[0][:400]); print("   sqlite:", w[1][:8]); print("   ours:  ", g[1][:8]); shown += 1
        if shown >= 3: break
PY
