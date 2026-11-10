#!/bin/sh
# Store.http against a real HTTP server: a store directory served by a static web server, which answers a trustless
# gateway's raw block requests (`GET /ipfs/<cid>?format=raw`) because it ignores the query. `obj` fetches a tree from
# it into an empty store, every block re-hashed; then one block on the server is tampered with, and a fresh fetch of
# what needs it is refused for that block, while the server's other blocks are still taken. Then the same over HTTPS
# (`Store.gateway`, through wac's fetch: `--mirror https://…`), against a local TLS server whose certificate the
# trust store is given by SSL_CERT_FILE, and refused when the certificate is not trusted.
#
#     sh packages/ipfs/tools/http-mirror.sh [WORKDIR]     (PORT defaults to 8770; needs python3 for the server)
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
port=${PORT:-8770}
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env packages/ipfs/cmd/obj.wac -o "$work/obj"
cd "$work"
O="wac $work/obj.wasm"
mkdir -p src/sub
printf 'hello\n' > src/a.txt
printf 'second file\n' > src/sub/b.txt
head -c 3000000 /dev/zero | tr '\0' 'x' > src/big.bin                     # three 1 MiB chunks and a root
tree=$($O add src --store served)
echo "tree $tree"

( cd served && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) & srv=$!
trap 'kill $srv 2>/dev/null || true' EXIT
until curl -s -m1 -o /dev/null "http://127.0.0.1:$port/"; do sleep 0.2; done
M="--mirror http://127.0.0.1:$port"

[ "$($O cat "$tree" a.txt --store fresh1 $M 2>&1)" = hello ] && ok "a file from the gateway, into an empty store" || bad "cat a.txt over http"
[ "$($O ls "$tree" --store fresh1 $M 2>&1 | wc -l)" -eq 3 ] && ok "the whole tree lists" || bad "ls over http: $($O ls "$tree" --store fresh1 $M 2>&1)"
[ "$($O cat "$tree" big.bin --store fresh1 $M | wc -c)" -eq 3000000 ] && ok "a 3 MB file in 1 MiB blocks" || bad "big.bin over http"
[ -n "$(ls fresh1/ipfs)" ] && ok "the blocks fetched are kept locally ($(ls fresh1/ipfs | wc -l))" || bad "nothing kept"

# Tamper with b.txt's block on the server: same name, other bytes.
leaf=$(basename "$(grep -lx 'second file' served/ipfs/* | head -1)")
[ -n "$leaf" ] && ok "b.txt is block $leaf" || bad "cannot find b.txt's block"
printf 'tampered!!!\n' > "served/ipfs/$leaf"
out=$($O cat "$tree" sub/b.txt --store fresh2 $M 2>&1) && got=ok || got=refused
[ "$got" = refused ] && printf '%s' "$out" | grep -q "does not hash to" && ok "a tampered block is refused: $(printf '%s' "$out" | grep -o 'mirror 0: [^;]*' | head -1)" \
  || bad "a tampered block was not refused ($got): $out"
# `obj cat TREE PATH` reads the whole tree, so it needs b.txt too; a.txt by its own CID does not.
a=$(basename "$(grep -lx hello served/ipfs/* | head -1)")
[ "$($O cat "$a" --store fresh2 $M 2>&1)" = hello ] && ok "the same server's other blocks still come through: a.txt, $a" || bad "a.txt after tampering"
out=$($O cat bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku --store fresh2 $M 2>&1) && got=ok || got=refused
[ "$got" = refused ] && ok "a block the server does not have: not here ($(printf '%s' "$out" | grep -o 'mirror 0: [^;]*' | head -1))" || bad "a missing block: $out"

# A mirror that fails (PORT+2): it answers 503, after 2 s, as a gateway whose origin is down does. Listed first, it is
# asked once, marked down, and asked nothing more, so the good mirror after it serves the tree without waiting on it
# for every block.
dport=$((port + 2))
printf 'second file\n' > "served/ipfs/$leaf"                          # the honest block back
cat > dead.mjs <<'JS'
import http from 'node:http'; import fs from 'node:fs';
let n = 0;
http.createServer((q, s) => { fs.writeFileSync('dead.hits', String(++n)); setTimeout(() => { s.statusCode = 503; s.end('down'); }, 2000); })
  .listen(Number(process.argv[2]), '127.0.0.1');
JS
node dead.mjs "$dport" & dsrv=$!
trap 'kill $srv $dsrv 2>/dev/null || true' EXIT
until curl -s -m3 -o /dev/null "http://127.0.0.1:$dport/"; do sleep 0.2; done
before=$(cat dead.hits)
t0=$(date +%s)
got=$($O ls "$tree" --store fresh6 --mirror "http://127.0.0.1:$dport" $M 2>&1 | wc -l)
t1=$(date +%s)
asked=$(( $(cat dead.hits) - before ))
[ "$got" -eq 3 ] && [ "$asked" -eq 1 ] && [ $((t1 - t0)) -lt 6 ] \
  && ok "a mirror answering 503 is asked once and then left out: the tree from the next, in $((t1 - t0)) s" \
  || bad "a failing mirror: $got files, it was asked $asked times, $((t1 - t0)) s"
kill $dsrv 2>/dev/null || true

# HTTPS: the same store behind a TLS server (PORT+1), as a trustless gateway is reached.
sport=$((port + 1))
printf 'second file\n' > "served/ipfs/$leaf"                          # the honest block back
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 -subj /CN=localhost \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
cat > https.py <<'PY'
import http.server, ssl, sys, functools
h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[2])

s = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), h)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("cert.pem", "key.pem")
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
python3 https.py "$sport" served 2>/dev/null & ssrv=$!
trap 'kill $srv $ssrv 2>/dev/null || true' EXIT
until curl -s -m1 --cacert cert.pem -o /dev/null "https://127.0.0.1:$sport/"; do sleep 0.2; done
S="--mirror https://127.0.0.1:$sport"
[ "$(SSL_CERT_FILE=$work/cert.pem $O cat "$tree" a.txt --store fresh3 $S 2>&1)" = hello ] && ok "over HTTPS: a file from the gateway, into an empty store" || bad "cat a.txt over https: $(SSL_CERT_FILE=$work/cert.pem $O cat "$tree" a.txt --store fresh3 $S 2>&1)"
[ "$(SSL_CERT_FILE=$work/cert.pem $O cat "$tree" big.bin --store fresh3 $S | wc -c)" -eq 3000000 ] && ok "over HTTPS: the 3 MB file" || bad "big.bin over https"
out=$($O cat "$tree" a.txt --store fresh4 $S 2>&1) && got=ok || got=refused
[ "$got" = refused ] && ok "a certificate the trust store does not hold: nothing fetched" || bad "an untrusted certificate was accepted: $out"
printf 'tampered!!!\n' > "served/ipfs/$leaf"
out=$(SSL_CERT_FILE=$work/cert.pem $O cat "$tree" sub/b.txt --store fresh5 $S 2>&1) && got=ok || got=refused
[ "$got" = refused ] && printf '%s' "$out" | grep -q "does not hash to" && ok "over HTTPS, a tampered block is refused" || bad "a tampered block over https ($got): $out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
