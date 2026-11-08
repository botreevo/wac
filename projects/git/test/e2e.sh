#!/bin/sh
# The server against real git: clone, fetch, ls-remote and push over HTTP, each judged by git.
#
#     sh test/e2e.sh          (or `wac task e2e`, with `wac` on PATH and `wac task deps` run once)
#
# Every check is git's own opinion of what the server did: `git fsck --strict` on what arrived, `git rev-parse`
# against the source of truth, `git ls-remote` over HTTP against `git ls-remote` on the directory itself. A
# server bug cannot pass by agreeing with itself, because no part of this reads anything the server wrote
# except through git.
set -eu

command -v git >/dev/null || { echo "e2e: SKIPPED — git is not installed"; exit 0; }
WAC=${WAC:-wac}
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
PORT=${PORT:-$((20000 + $$ % 20000))}
URL=http://127.0.0.1:$PORT
fails=0
SERVER=

cleanup() { [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { name=$1; shift; if "$@" >"$T/out" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/     /' "$T/out"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "     expected: $3"; echo "     got:      $2"; fi; }

export GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@b GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@b
export GIT_CONFIG_NOSYSTEM=1 HOME=$T/home GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global init.defaultBranch main
git config --global protocol.file.allow always

# ── The fixture: two branches, a subdirectory, an executable, a symlink, annotated and light tags ──
mkdir -p "$T/root" "$T/src"
git init -q --bare "$T/root/demo.git"
cd "$T/src"
git init -q
mkdir -p dir/deeper
echo hello > a.txt
echo nested > dir/deeper/b.txt
printf '#!/bin/sh\necho hi\n' > run.sh && chmod +x run.sh
ln -s a.txt link
git add -A && git commit -qm one
echo more >> a.txt && git commit -qam two
git tag -a v1 -m "version one"
git tag light
git checkout -qb feature
echo feature > f.txt && git add f.txt && git commit -qm feature
git checkout -q main
git push -q "$T/root/demo.git" main feature v1 light

echo secret-token > "$T/token"
mkdir -p "$T/build"
$WAC build --allow-read --allow-write --allow-net "$HERE/cmd/gitserve.wac" -o "$T/build/gitserve" >/dev/null
$WAC "$T/build/gitserve.wasm" "$T/root" --port "$PORT" --push-token-file "$T/token" --create-on-push \
  >"$T/server.log" 2>&1 &
SERVER=$!
i=0
until curl -fsS "$URL/" >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -gt 200 ] && { echo "e2e: the server did not start"; cat "$T/server.log"; exit 1; }
  sleep 0.1
done

# ── Reading ──
same "the listing names the repository" "$(curl -fsS "$URL/")" "demo.git"
same "ls-remote over HTTP agrees with ls-remote on the directory" \
  "$(git ls-remote "$URL/demo.git")" "$(git ls-remote "$T/root/demo.git")"
same "ls-remote with protocol v0 agrees too" \
  "$(git -c protocol.version=0 ls-remote "$URL/demo")" "$(git ls-remote "$T/root/demo.git")"

check "clone (protocol v2)" git clone -q "$URL/demo.git" "$T/c2"
check "the clone passes fsck --strict" git -C "$T/c2" fsck --strict
same "the clone's HEAD is main's commit" "$(git -C "$T/c2" rev-parse HEAD)" "$(git -C "$T/src" rev-parse main)"
same "the clone has the feature branch" "$(git -C "$T/c2" rev-parse origin/feature)" "$(git -C "$T/src" rev-parse feature)"
same "the annotated tag came with it" "$(git -C "$T/c2" rev-parse v1)" "$(git -C "$T/src" rev-parse v1)"
same "the light tag came with it" "$(git -C "$T/c2" rev-parse light)" "$(git -C "$T/src" rev-parse light)"
same "the working tree is clean" "$(git -C "$T/c2" status --porcelain)" ""
same "the executable kept its bit" "$(git -C "$T/c2" ls-files -s run.sh | cut -c1-6)" "100755"
same "the symlink is a symlink" "$(readlink "$T/c2/link")" "a.txt"

check "clone (protocol v0)" git -c protocol.version=0 clone -q "$URL/demo.git" "$T/c0"
check "the v0 clone passes fsck --strict" git -C "$T/c0" fsck --strict
same "the v0 clone's HEAD is main's commit" "$(git -C "$T/c0" rev-parse HEAD)" "$(git -C "$T/src" rev-parse main)"

# An incremental fetch: three new commits upstream, and the clone asks for only those.
cd "$T/src"
for n in 3 4 5; do echo "$n" >> dir/deeper/b.txt; git commit -qam "commit $n"; done
git push -q "$T/root/demo.git" main
check "fetch (protocol v2)" git -C "$T/c2" fetch -q origin
same "the fetch moved origin/main" "$(git -C "$T/c2" rev-parse origin/main)" "$(git -C "$T/src" rev-parse main)"
check "the fetched repository passes fsck --strict" git -C "$T/c2" fsck --strict
# The fetch should carry the three commits and, for each, the three trees on the path to the file it changed and
# the file: fifteen objects. The whole history is more than twice that.
newest=$(ls -t "$T/c2/.git/objects/pack/"*.pack | head -1)
nobj=$(git -C "$T/c2" verify-pack -v "$newest" | grep -cE ' (commit|tree|blob|tag) ')
same "the fetch carried only what was new" "$nobj" "15"
check "fetch (protocol v0)" git -C "$T/c0" -c protocol.version=0 fetch -q origin
same "the v0 fetch moved origin/main" "$(git -C "$T/c0" rev-parse origin/main)" "$(git -C "$T/src" rev-parse main)"

# ── Writing ──
cd "$T/c2"
git pull -q --ff-only
echo pushed > p.txt && git add p.txt && git commit -qm pushed
if git push -q origin main 2>/dev/null; then bad "a push without credentials is refused"; else ok "a push without credentials is refused"; fi
if git push -q "http://u:wrong@127.0.0.1:$PORT/demo.git" main 2>/dev/null; then bad "a push with the wrong token is refused"; else ok "a push with the wrong token is refused"; fi
same "and the ref did not move" "$(git -C "$T/root/demo.git" rev-parse main)" "$(git -C "$T/src" rev-parse main)"
AUTH="http://anyone:secret-token@127.0.0.1:$PORT/demo.git"
check "a push with the token" git push -q "$AUTH" main
same "the server's main is the pushed commit" "$(git -C "$T/root/demo.git" rev-parse main)" "$(git rev-parse HEAD)"
check "the server's repository passes fsck --strict" git -C "$T/root/demo.git" fsck --strict

# A push larger than git's post buffer goes chunked.
head -c 3000000 /dev/urandom > big.bin && git add big.bin && git commit -qm big
check "a 3 MB push (a chunked body)" git push -q "$AUTH" main
same "the server has it" "$(git -C "$T/root/demo.git" rev-parse main:big.bin)" "$(git rev-parse HEAD:big.bin)"
check "and still passes fsck --strict" git -C "$T/root/demo.git" fsck --strict

# A push building on what the server has must not resend it: the server completes a thin pack.
echo thin >> a.txt && git commit -qam thin
check "a thin push" git push -q "$AUTH" main
check "after the thin push, fsck --strict" git -C "$T/root/demo.git" fsck --strict

check "a new branch and a new tag" git push -q "$AUTH" HEAD:refs/heads/topic
git tag -a v2 -m two && check "an annotated tag" git push -q "$AUTH" v2
same "the tag on the server" "$(git -C "$T/root/demo.git" rev-parse v2)" "$(git rev-parse v2)"
check "a branch deleted" git push -q "$AUTH" :topic
if git -C "$T/root/demo.git" rev-parse -q --verify refs/heads/topic >/dev/null; then bad "the deleted branch is gone"; else ok "the deleted branch is gone"; fi

# A non-fast-forward, refused by the client unless forced, then forced: the server takes it.
git reset -q --hard HEAD~1
if git push -q "$AUTH" main 2>/dev/null; then bad "a non-fast-forward is refused without --force"; else ok "a non-fast-forward is refused without --force"; fi
check "a forced push" git push -q --force "$AUTH" main
same "the forced push moved main back" "$(git -C "$T/root/demo.git" rev-parse main)" "$(git rev-parse HEAD)"

# The compare-and-swap, which git's client never lets a test reach — it checks a lease against the
# advertisement itself. So the request is written by hand: move main from a value it does not have.
head=$(git -C "$T/root/demo.git" rev-parse main)
older=$(git -C "$T/root/demo.git" rev-parse main~1)
line="$older $older refs/heads/main"
printf '%04x%s\000report-status\n0000' $((${#line} + 4 + 15)) "$line" > "$T/stale.req"
curl -s -u x:secret-token -H 'Content-Type: application/x-git-receive-pack-request' \
  --data-binary @"$T/stale.req" "$URL/demo.git/git-receive-pack" > "$T/stale.out"
case "$(cat "$T/stale.out")" in
  *"ng refs/heads/main stale info"*) ok "an update from a stale old value is refused";;
  *) bad "an update from a stale old value is refused"; echo "     $(cat "$T/stale.out")";;
esac
same "and main did not move" "$(git -C "$T/root/demo.git" rev-parse main)" "$head"

# atomic: one good update and one bad one, and neither happens.
before=$(git -C "$T/root/demo.git" rev-parse main)
echo atomic >> a.txt && git commit -qam atomic
if git push -q --atomic "$AUTH" main "$(git rev-parse HEAD~1):refs/heads/feature" 2>/dev/null; then
  bad "an atomic push with one refused update is refused whole"; else ok "an atomic push with one refused update is refused whole"; fi
same "and main did not move" "$(git -C "$T/root/demo.git" rev-parse main)" "$before"

# A repository that does not exist yet, made by the push.
mkdir "$T/fresh" && cd "$T/fresh" && git init -q -b trunk && echo x > x && git add x && git commit -qm x
check "a push creates a repository" git push -q "http://u:secret-token@127.0.0.1:$PORT/new/project.git" trunk
check "it clones, with HEAD on the pushed branch" git clone -q "$URL/new/project" "$T/fresh-clone"
same "the clone checked out trunk" "$(git -C "$T/fresh-clone" rev-parse --abbrev-ref HEAD)" "trunk"
same "the listing has both" "$(curl -fsS "$URL/" | tr '\n' ' ')" "demo.git new/project.git "

# The dumb protocol, and a path that tries to leave the root.
same "the dumb protocol is refused" "$(curl -s -o /dev/null -w '%{http_code}' "$URL/demo.git/info/refs")" "403"
same "a path with .. is not a repository" "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "$URL/../demo.git/info/refs?service=git-upload-pack")" "404"

echo
if [ $fails -eq 0 ]; then echo "e2e: all passed"; else echo "e2e: $fails failed"; echo "--- server log"; tail -40 "$T/server.log"; exit 1; fi
