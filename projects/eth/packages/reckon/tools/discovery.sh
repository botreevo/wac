#!/bin/sh
# Finding mirrors (docs/discovery.md): manifests, static files that name mirrors and further manifests, followed from one
# URL to every mirror they lead to. Two static sites, each with CORS on everything, each carrying one mirror below its
# root and a manifest; the claims a decision needs are split between the two mirrors. Checked:
#   - every answer a browser would read carries `Access-Control-Allow-Origin: *`, and a preflight is answered;
#   - `claim mirrors URL` finds both mirrors from the first manifest: one named relatively, one through a second
#     manifest, a cycle back followed once, and a missing manifest and one that is not JSON reported, not fatal;
#   - admission with the mirrors found admits, where either mirror alone does not;
#   - a manifest that leads to a lying mirror costs nothing: its forged statement is left out and reported;
#   - a long chain of manifests stops at the limit, and says so;
#   - mirrors given by hand work as before.
#
#     sh packages/reckon/tools/discovery.sh WORKDIR     (PORT defaults to 8860; the second site is PORT+1, the third PORT+2)
#
# Needs: wac on PATH, python3 and curl.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
work=${1:?WORKDIR}; rm -rf "$work"; mkdir -p "$work"; work=$(cd "$work" && pwd)
p1=${PORT:-8860}; p2=$((p1 + 1)); p3=$((p1 + 2))
pass=0; fail=0
step() { printf '\n== %s\n' "$*"; }
ok() { pass=$((pass + 1)); echo "ok    $*"; }
bad() { fail=$((fail + 1)); echo "FAIL  $*"; }

cd "$root"
wac build --quiet --allow-read --allow-write --allow-net --allow-env --allow-run "$here/cmd/claim.wac" -o "$work/claim"
CL="wac $work/claim.wasm"
cd "$work"
printf '%s\n' a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 > alice.key
printf '%s\n' b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2 > bob.key
printf '%s\n' c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3 > carol.key
subject=bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku
cat > policy.json5 <<POLICY
{ signers: { alice: "$($CL address --key alice.key)", bob: "$($CL address --key bob.key)" },
  roles: { app: [{ endorsed: { by: ["alice", "bob"], at_least: 2 } }] } }
POLICY
admit() { $CL admit "$subject" app --policy policy.json5 "$@" > admit.log 2>&1 && echo yes || echo no; }

step "two sites, each carrying one mirror below its root, and a manifest"
mkdir -p site1/a site2/deep site3
$CL endorse "$subject" reviewed --key alice.key --store alice >/dev/null 2>&1
$CL endorse "$subject" reviewed --key bob.key --store bob >/dev/null 2>&1
$CL publish site1/a/mirror --store alice >/dev/null
$CL publish site2/deep/b --store bob >/dev/null
u1="http://127.0.0.1:$p1"; u2="http://127.0.0.1:$p2"; u3="http://127.0.0.1:$p3"
# The first names its own mirror relatively; follows the second, a manifest that is not there, and one that is not JSON.
$CL manifest site1/reckon-mirrors.json --lists a/mirror --follow "$u2/reckon-mirrors.json" --follow "$u1/missing.json" \
  --follow "$u2/garbage.json" >/dev/null
# The second names its mirror and follows the first back: a cycle.
$CL manifest site2/reckon-mirrors.json --lists deep/b --follow "$u1/reckon-mirrors.json" >/dev/null
printf '<html>not a manifest</html>\n' > site2/garbage.json
sed 's/^/   | /' site1/reckon-mirrors.json
for s in 1 2 3; do eval "port=\$p$s"; python3 "$here/tools/serve.py" "$port" "site$s" & eval "srv$s=\$!"; done
trap 'kill $srv1 $srv2 $srv3 2>/dev/null || true' EXIT INT TERM
for u in "$u1" "$u2" "$u3"; do until curl -s -m1 -o /dev/null "$u/"; do sleep 0.2; done; done

step "CORS on everything a page reads"
block=$(sed -n 's/^signed //p' site1/a/mirror/claims/index | head -1)
for path in "$u1/reckon-mirrors.json" "$u1/a/mirror/claims/index" "$u1/a/mirror/ipfs/$block"; do
  curl -s -D - -o /dev/null "$path" | tr -d '\r' | grep -qi '^Access-Control-Allow-Origin: \*$' || { bad "no CORS header on $path"; continue; }
done
[ "$fail" -eq 0 ] && ok "Access-Control-Allow-Origin: * on the manifest, the index and a block"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$u1/reckon-mirrors.json")" = 204 ] && ok "a preflight is answered" || bad "no preflight answer"

step "from one URL, every mirror"
$CL mirrors "$u1/reckon-mirrors.json" > found 2> problems || true
sed 's/^/   | /' found; sed 's/^/   ! /' problems
[ "$(cat found)" = "$(printf '%s\n%s' "$u1/a/mirror" "$u2/deep/b")" ] \
  && ok "both mirrors, the relative one resolved, the second through the second manifest, the cycle followed once" || bad "found: $(cat found)"
grep -q "missing.json: HTTP 404" problems && grep -q "garbage.json: not JSON" problems \
  && ok "a missing manifest and one that is not JSON are reported, not fatal" || bad "problems: $(cat problems)"

step "admission, from what was found"
set -- $(sed 's/^/--mirror /' found)
[ "$(admit --store client1 "$@")" = yes ] && ok "with the mirrors found: both endorsements, admitted" || bad "refused: $(cat admit.log)"
[ "$(admit --store client2 --mirror "$u1/a/mirror")" = no ] && ok "with only the first site's mirror: refused" || bad "admitted on one"
[ "$(admit --store client3 --mirror "$u2/deep/b")" = no ] && ok "with only the second's: refused" || bad "admitted on one"

step "a manifest that leads to a lying mirror"
$CL endorse "$subject" reviewed --key carol.key --store carol >/dev/null 2>&1
cp -r site1/a/mirror site3/liar
first=$(sed -n 's/^signed //p' site3/liar/claims/index | head -1)
$CL publish site3/liar --store carol >/dev/null
other=$(sed -n 's/^signed //p' site3/liar/claims/index | grep -v "$first" | head -1)
cp "site3/liar/ipfs/$other" "site3/liar/ipfs/$first"          # alice's statement's name, carol's bytes
$CL manifest site3/reckon-mirrors.json --lists liar --follow "$u1/reckon-mirrors.json" >/dev/null
$CL mirrors "$u3/reckon-mirrors.json" > found3 2>/dev/null || true
[ "$(wc -l < found3)" -eq 3 ] && ok "the third manifest leads to three mirrors, its liar first" || bad "found3: $(cat found3)"
set -- $(sed 's/^/--mirror /' found3)
[ "$(admit --store client4 "$@")" = yes ] && grep -q "left out: mirror 0" admit.log \
  && ok "the liar's forged statement is left out and named, and the honest mirrors still decide" || bad "with the liar: $(cat admit.log)"

step "limits"
mkdir -p site3/chain
i=0; while [ $i -lt 20 ]; do $CL manifest "site3/chain/$i.json" --follow "$((i + 1)).json" >/dev/null; i=$((i + 1)); done
$CL mirrors "$u3/chain/0.json" > /dev/null 2> chain.log || true
grep -q "past the limit of 16 manifests" chain.log && ok "a chain of 20 manifests stops at 16, and says so" || bad "chain: $(cat chain.log)"

step "mirrors given by hand, as before"
[ "$(admit --store client5 --mirror "$u1/a/mirror" --mirror "$u2/deep/b")" = yes ] && ok "mirrors given by hand still work" || bad "by hand: $(cat admit.log)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
