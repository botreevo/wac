#!/bin/sh
# Dependencies pinned by CID (docs/lock.md, cmd/deps.wac), on wac-web as wac.lock pins it, in a package cache of the
# script's own (WAC_HOME under WORKDIR): pin, check, a tampered cache, fetch from a mirror and from git, a lying
# mirror and a wrong pin, and admission of each locked CID under a policy.
#
#     sh tools/deps-lock.sh [WORKDIR]       # needs network for git.voltrevo.com, and wac-web in the real cache
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
entry=$(tr '\n' ' ' < wac.lock | grep -o '"web": *{[^}]*}')
git=$(printf '%s' "$entry" | sed -n 's/.*"git": *"\([^"]*\)".*/\1/p')
commit=$(printf '%s' "$entry" | sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p')
esc=$(python3 -c 'import sys; print("".join(c if c.islower() or c.isdigit() or c in "._-" else ("!"+c.lower() if c.isupper() else "%%%02X" % ord(c)) for c in sys.argv[1]))' "$git")
real="${WAC_HOME:-$HOME/.wac}/cache/git/$esc/$commit"
[ -f "$real/pack.pack" ] || { echo "deps-lock: wac-web is not in the cache at $real (sh tools/deps.sh)" >&2; exit 2; }
wac build --quiet --allow-read --allow-write --allow-run --allow-env --allow-net packages/reckon/cmd/deps.wac -o "$work/deps"
wac build --quiet --allow-read --allow-write --allow-run --allow-net packages/ipfs/cmd/obj.wac -o "$work/obj"
wac build --quiet --allow-read --allow-write --allow-run --allow-net packages/reckon/cmd/claim.wac -o "$work/claim"

cd "$work"
rm -rf home* pub lie s-* repo lock*.json5 && mkdir -p "home/cache/git/$esc"
cp -r "$real" "home/cache/git/$esc/$commit"
printf '{\n  "imports": {\n    "web": { "git": "%s", "ref": "%s", "commit": "%s" }\n  }\n}\n' "$git" "$commit" "$commit" > lock.json5
deps() { h=$1; shift; WAC_HOME="$work/$h" wac deps.wasm "$@" --lock lock.json5; }
cache="home/cache/git/$esc/$commit"

step "pin: the cache checkout, less its marker, is the commit's tree"
deps home pin --store pub >/dev/null 2>&1 && cid=$(deps home cids | sed -n 's/^web //p')
git clone -q --bare "$git" repo
fromGit=$(wac obj.wasm add-git repo "$commit" --store s-git)
[ -n "$cid" ] && [ "$cid" = "$fromGit" ] && ok "pinned $cid, which is obj add-git of the commit" || bad "pinned '$cid', git says $fromGit"
grep -q "\"cid\": \"$cid\"" lock.json5 && ok "and written into the lock" || bad "the lock: $(cat lock.json5)"
cp lock.json5 lock.before
deps home pin >/dev/null 2>&1; cmp -s lock.json5 lock.before && ok "pin again: nothing changes" || bad "a second pin changed the lock"

step "check"
deps home check >/dev/null 2>&1 && ok "the cache is what the lock pins" || bad "check: $(deps home check 2>&1)"
f=$(cd "$cache" && find . -type f -name '*.wac' | head -1)
cp "$cache/$f" saved && printf 'x' >> "$cache/$f"
deps home check > check.log 2>&1 && bad "a changed byte passed" || { grep -q "the cache holds" check.log && ok "one byte added to $f: refused" || bad "$(cat check.log)"; }
cp saved "$cache/$f"
sed 's/, "cid": "[^"]*"//' lock.json5 > lock.unpinned.json5
WAC_HOME="$work/home" wac deps.wasm check --lock lock.unpinned.json5 > check.log 2>&1 && bad "an unpinned entry passed" \
  || { grep -q "not pinned" check.log && ok "an entry without a cid is refused, not passed" || bad "$(cat check.log)"; }

step "fetch from a mirror: every block checked, installed only as the pinned tree"
deps home2 fetch --store s-2 --mirror pub > fetch.log 2>&1 && deps home2 check >/dev/null 2>&1 \
  && ok "fetched by CID from the mirror into an empty cache, and it checks" || bad "$(cat fetch.log)"
diff -r "$cache" "home2/cache/git/$esc/$commit" >/dev/null && ok "the same files as the original checkout, marker included" || bad "the fetched checkout differs"
cp -r pub lie
blk=$(find lie -type f -path '*ipfs*' | head -1); printf 'other bytes' > "$blk"
deps home3 fetch --store s-3 --mirror lie > lie.log 2>&1 && bad "a lying mirror was installed" \
  || { [ ! -e "home3/cache/git/$esc/$commit/pack.pack" ] && ok "a mirror with one block changed: refused, and nothing marked complete in the cache" || bad "$(cat lie.log)"; }

step "fetch from git: imported, compared with the pin, then kept"
deps home4 fetch --git --store s-4 > git.log 2>&1 && deps home4 check >/dev/null 2>&1 \
  && ok "fetched from $git, and it checks" || bad "$(cat git.log)"
sed "s/\"cid\": \"[^\"]*\"/\"cid\": \"$(wac obj.wasm add "$here/docs/decisions" --store s-x)\"/" lock.json5 > lock.wrong.json5
WAC_HOME="$work/home5" wac deps.wasm fetch --git --store s-5 --lock lock.wrong.json5 > wrong.log 2>&1 && bad "a wrong pin was installed" \
  || { grep -q "refused, nothing kept" wrong.log && [ ! -e "home5/cache/git/$esc/$commit" ] && ok "a pin the commit is not: refused, nothing in the cache" || bad "$(cat wrong.log)"; }

step "admit: each locked CID under a policy"
printf '%s\n' add2f9f8b6e2bff7d0b6e7d1bbcd8fe16c3fbd8b5b1fbb1c0a63e5a0e7a2c3b1 > reviewer.key
cat > policy.json5 <<EOF
{
  signers: { reviewer: "$(wac claim.wasm address --key reviewer.key)" },
  machines: ["wasm-gc/wac-host/2"],
  formats: ["unixfs-v1-2025+hidden"],
  roles: { dependency: [{ endorsed: { by: ["reviewer"], at_least: 1 } }] },
}
EOF
code=0; deps home admit dependency --policy policy.json5 --store pub > admit.log 2>&1 || code=$?
[ $code -eq 4 ] && grep -q "^REFUSED web" admit.log && ok "unreviewed: refused (4)" || bad "exit $code: $(cat admit.log)"
wac claim.wasm endorse "$cid" reviewed --key reviewer.key --store pub >/dev/null 2>&1
deps home admit dependency --policy policy.json5 --store pub > admit.log 2>&1 && grep -q "^ADMITTED web $cid" admit.log \
  && ok "reviewed: admitted" || bad "$(cat admit.log)"

step "a lock holding a field this does not know is not rewritten"
sed 's/"commit"/"extra": "x", "commit"/' lock.unpinned.json5 > lock.extra.json5
cp lock.extra.json5 lock.extra.before
WAC_HOME="$work/home" wac deps.wasm pin --lock lock.extra.json5 > extra.log 2>&1 && bad "pinned and dropped a field" \
  || { cmp -s lock.extra.json5 lock.extra.before && grep -q "would lose it" extra.log && ok "refused, the lock unchanged" || bad "$(cat extra.log)"; }

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
