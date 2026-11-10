#!/bin/sh
# `claim run`: admit, fetch, check, run, in one command (cmd/claim.wac). No chain: the policy admits what a reviewer
# endorsed, so what is checked here is everything after the decision: the bytes fetched from a mirror and checked
# against their CID, the program run sealed with only its own tree, its output and exit code passed on, --out, and
# the refusals: nothing runs that was not admitted, and nothing runs that does not hash.
#
#     sh tools/run.sh [WORKDIR]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }
step() { echo; echo "## $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-run --allow-net --allow-env packages/reckon/cmd/claim.wac -o "$work/claim"
wac build --quiet --allow-read --allow-write --allow-net packages/ipfs/cmd/obj.wac -o "$work/obj"
wac build --quiet packages/reckon/corpus/probe.wac -o "$work/probe"

cd "$work"
rm -rf pub client client2 out out-tree tree bad-mirror && mkdir -p tree/assets/empty
cat > app.wac <<'EOF'
// An app that is a tree: it reads its own data, and says what it was given.
import { Sys } from "std";
export async i32 main(Sys sys) {
  auto d = await sys.readFile("/in/assets/data.txt");
  sys.log(d.isOk() ? "data: \{string.fromBytes(d.unwrap())}" : "data: refused \{d.err()!}");
  auto h = await sys.readFile("/etc/hostname");
  sys.log(h.isOk() ? "host file: read" : "host file: refused");
  string[] a = sys.args();
  string all = "";
  for (i32 i = 0; i < a.len(); i++) { all += " " + a[i]; }
  sys.log("args:\{all}");
  auto w = await sys.writeFile("/out/note", "kept in memory".toBytes());
  sys.log(w.isOk() ? "wrote /out/note" : "refused /out/note");
  auto ro = await sys.writeFile("/in/assets/data.txt", "changed".toBytes());
  sys.log(ro.isOk() ? "changed its own tree" : "its own tree is read-only");
  sys.warn("to stderr");
  return 7;
}
EOF
(cd "$root" && wac build --quiet "$work/app.wac" -o "$work/tree/app")
printf 'from the tree' > tree/assets/data.txt
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key
mkdir -p probe-dir && cp probe.wasm probe-dir/probe.wasm

# The publisher's store: both objects, the reviewer's endorsements, published as a mirror.
P="--store pub"
treeCid=$(wac obj.wasm add tree $P)
wac obj.wasm add probe-dir $P >/dev/null
probeCid=$(python3 -c "import sys,hashlib,base64; d=hashlib.sha256(open(sys.argv[1],'rb').read()).digest(); print('b'+base64.b32encode(bytes([1,0x55,0x12,0x20])+d).decode().lower().rstrip('='))" probe.wasm)
wac claim.wasm endorse "$treeCid" reviewed --key reviewer.key $P >/dev/null 2>&1
wac claim.wasm endorse "$probeCid" reviewed --key reviewer.key $P >/dev/null 2>&1
wac claim.wasm publish pub $P >/dev/null
cat > policy.json5 <<EOF
{
  signers: { reviewer: "$(wac claim.wasm address --key reviewer.key)" },
  machines: ["wasm-gc/wac-host/2"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: { app: [{ endorsed: { by: ["reviewer"], at_least: 1 } }] },
}
EOF
# A fresh client: an empty store and the mirror.
C="--policy policy.json5 --store client --mirror pub"

step "a program that is one file: admitted, fetched, run sealed"
code=0; wac claim.wasm run "$probeCid" app $C -- one two > probe.out 2> probe.err || code=$?
[ $code -eq 0 ] && ok "it ran, and exited 0" || bad "exit $code: $(cat probe.err)"
grep -q ADMITTED probe.err && ! grep -q ADMITTED probe.out && ok "admission's account is on stderr; stdout is the program's" \
  || bad "the account: $(cat probe.out)"
grep -q "^clock: refused" probe.out && grep -q "^random: refused" probe.out && ok "sealed: no clock and no random bytes" \
  || bad "sealed? $(cat probe.out)"
grep -q "^read /etc/hostname: refused" probe.out && grep -q "^env HOME: refused" probe.out \
  && ok "no host files and no environment" || bad "$(cat probe.out)"
grep -q "^args: 2" probe.out && ok "the arguments after -- are the program's" || bad "$(grep args probe.out)"

step "a program that is a tree: --entry names it, and it sees its own files and nothing else"
code=0; wac claim.wasm run "$treeCid" app $C --entry app.wasm -- --x y > tree.out 2> tree.err || code=$?
[ $code -eq 7 ] && ok "its exit code is the command's (7)" || bad "exit $code: $(cat tree.err)"
grep -q "^data: from the tree" tree.out && ok "it read its own tree, at /in" || bad "$(cat tree.out)"
grep -q "^wrote /out/note" tree.out && grep -q "^its own tree is read-only" tree.out \
  && ok "it may write /out (kept in memory, then dropped), not /in" || bad "$(cat tree.out)"
grep -q "^host file: refused" tree.out && ok "and not the host's files" || bad "$(cat tree.out)"
grep -q "^args: --x y" tree.out && ok "a flag after -- is the program's, not claim's" || bad "$(grep args tree.out)"
grep -q "to stderr" tree.err && ok "its stderr is passed on" || bad "stderr: $(cat tree.err)"
code=0; wac claim.wasm run "$treeCid" app $C > /dev/null 2> noentry.err || code=$?
[ $code -eq 2 ] && grep -q "with --entry PATH" noentry.err && ok "a tree without --entry is not guessed at" || bad "exit $code: $(cat noentry.err)"

step "--out: the admitted bytes, written out instead of run"
wac claim.wasm run "$probeCid" app $C --out out.wasm 2>/dev/null && cmp -s out.wasm probe.wasm \
  && ok "a file: the same bytes" || bad "--out of a file"
wac claim.wasm run "$treeCid" app $C --out out-tree 2>/dev/null && cmp -s out-tree/app.wasm tree/app.wasm \
  && cmp -s out-tree/assets/data.txt tree/assets/data.txt && [ -d out-tree/assets/empty ] \
  && ok "a tree: every file, and its empty directory" || bad "--out of a tree: $(find out-tree | head)"

step "what does not run"
code=0; wac claim.wasm run "$probeCid" app --policy policy.json5 --store client2 > unend.out 2> unend.err || code=$?
# client2 has no mirror, so no endorsement: refused at admission, before anything is fetched.
[ $code -eq 4 ] && grep -q REFUSED unend.err && [ ! -s unend.out ] && ok "not admitted: refused (4), and nothing ran" \
  || bad "exit $code: $(cat unend.err)"
cp -r pub bad-mirror
blk=$(find bad-mirror -type f -name "*$(echo "$probeCid" | cut -c2-)*" | head -1)
if [ -n "$blk" ]; then
  printf 'other bytes' > "$blk"
  code=0; wac claim.wasm run "$probeCid" app --policy policy.json5 --store client3 --mirror bad-mirror > lie.out 2> lie.err || code=$?
  [ $code -eq 1 ] && [ ! -s lie.out ] && grep -q "does not hash\|hash" lie.err && ok "a mirror serving other bytes: admitted, then refused at the fetch (1), and nothing ran" \
    || bad "exit $code: $(cat lie.err)"
else
  bad "could not find the probe's block in the mirror to tamper with: $(find bad-mirror -type f | head -3)"
fi

step "a mirror over HTTPS, as a public trustless gateway is reached (--mirror https://…)"
sport=${PORT:-8790}
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
python3 https.py "$sport" pub 2>/dev/null & srv=$!
trap 'kill $srv 2>/dev/null || true' EXIT
until curl -s -m1 --cacert cert.pem -o /dev/null "https://127.0.0.1:$sport/"; do sleep 0.2; done
rm -rf client-tls
code=0; SSL_CERT_FILE="$work/cert.pem" wac claim.wasm run "$treeCid" app --policy policy.json5 --store client-tls --mirror "https://127.0.0.1:$sport" \
  --entry app.wasm > tls.out 2> tls.err || code=$?
[ $code -eq 7 ] && grep -q "^data: from the tree" tls.out && ok "claims and blocks over TLS: admitted, fetched, run" || bad "exit $code: $(tail -3 tls.err)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
