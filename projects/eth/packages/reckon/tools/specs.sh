#!/bin/sh
# The machines' defining texts are named by CID in docs/machines/README.md. Each line there of the form
#
#     | `MACHINE` | `PATH` | `CID` | …
#
# names a file (in this repository, or `wac:PATH` in the pinned wac source) and the CID its bytes must have. This
# checks every one, so an edit to a definition cannot go unnoticed: a changed definition is a new machine.
#
#     sh packages/reckon/tools/specs.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
commit=$(sed -n 's/.*"wac": {.*"commit": "\([0-9a-f]\{40\}\)".*/\1/p' "$root/wac.lock" | head -1)
wacsrc=${WACSRC:-$HOME/.wac/cache/git/https%3A%2F%2Fgit.voltrevo.com%2Fwac.git/$commit}
pass=0; fail=0
# The CID of a file of at most 1 MiB under unixfs-v1-2025: one raw block, so the raw CID of its SHA-256.
cid() { python3 -c "import sys,hashlib,base64; b=open(sys.argv[1],'rb').read(); assert len(b) <= 1<<20; d=hashlib.sha256(b).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))" "$1"; }
grep -E '^\| `[^`]+` \| `[^`]+` \| `bafk[a-z2-7]+` \|' "$here/docs/machines/README.md" | while IFS='|' read -r _ m p c _; do
  m=$(echo "$m" | tr -d ' `'); p=$(echo "$p" | tr -d ' `'); c=$(echo "$c" | tr -d ' `')
  case $p in wac:*) f="$wacsrc/${p#wac:}" ;; *) f="$here/$p" ;; esac
  got=$(cid "$f")
  if [ "$got" = "$c" ]; then echo "ok    $m: $p is $c"; else echo "FAIL  $m: $p is $got, not $c"; fi
done | tee /dev/stderr | grep -q '^FAIL' && exit 1
exit 0
