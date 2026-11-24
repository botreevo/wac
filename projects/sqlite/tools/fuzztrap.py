"""Finds the first statement of test/corpus/fuzz.sql that makes the wac side trap, by bisection."""
import subprocess, os
lines = open('test/corpus/fuzz.sql').read().splitlines()
head = [l for l in lines if not l.startswith('SELECT')]
body = [l for l in lines if l.startswith('SELECT')]
def ok(n):
    open('dist/f.sql', 'w').write("\n".join(head + body[:n]) + "\n")
    r = subprocess.run(['wac', 'run', '--allow-read', 'tools/corpus_run.wac', '--', 'dist/f.sql'], capture_output=True, text=True)
    return r.stdout != ''
lo, hi = 0, len(body)
while lo < hi:
    mid = (lo + hi) // 2
    if ok(mid): lo = mid + 1
    else: hi = mid
print(body[lo - 1] if lo > 0 else "(no trap)")
