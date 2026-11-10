#!/bin/sh
# reckon's pages site in dist/site: the landing page (site/index.html), and the demos as recorded runs of the
# repository's own scripts (site/demos/*.txt), each on its own page. Served from the `pages` branch, as wac-eth's
# site, at https://pages.voltrevo.com/wac-eth/.
#
#     sh packages/reckon/tools/site.sh                 build dist/site from what is recorded
#     WASMTIME_WAC=… sh packages/reckon/tools/site.sh --record WORKDIR [DEMO…]
#                                                      run the demos (all nine, or those named) again into
#                                                      site/demos first (about 30 minutes for all; ladder.sh and
#                                                      flatten.sh take LADDER or build the ladder with cargo; a demo
#                                                      that fails stops it), then build
#     sh packages/reckon/tools/site.sh --publish       build, then commit dist/site as the `pages` branch's next
#                                                      commit and push it (needs a clean checkout: it names the commit)
#
# Needs python3; recording needs what the demos need (see each script).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)
out=$here/dist/site

if [ "${1:-}" = --record ]; then
  work=${2:?--record WORKDIR}
  : "${WASMTIME_WAC:?set WASMTIME_WAC to the wac of the native host}"
  mkdir -p "$work"
  cd "$root"
  shift 2
  demos=${*:-demo admit-by-name claims-mirror selfbuild capstone ladder l0 flatten conformance}
  for d in $demos; do
    echo "recording $d"
    case $d in
      selfbuild) env SELF=1 sh "$here/tools/$d.sh" "$work/$d" ;;
      capstone) env QUICK=1 sh "$here/tools/$d.sh" "$work/$d" ;;
      *) sh "$here/tools/$d.sh" "$work/$d" ;;
    esac > "$work/$d.txt" 2>&1 || { echo "site: $d failed; see $work/$d.txt"; exit 1; }
    # Paths of this machine's work directory are not part of what was shown.
    sed "s|$work/$d|WORKDIR|g; s|$root|wac-eth|g; s|$HOME|~|g" "$work/$d.txt" > "$here/site/demos/$d.txt"
    echo "$(date -u +%Y-%m-%d) $(git -C "$root" rev-parse --short HEAD)" > "$here/site/demos/$d.recorded"
  done
fi

rm -rf "$out"
python3 "$here/tools/site.py" "$out" "$(git -C "$root" rev-parse --short HEAD)"

if [ "${1:-}" = --publish ]; then
  [ -z "$(git -C "$root" status --porcelain)" ] || { echo "site: commit first: the pages commit names the source commit"; exit 1; }
  src=$(git -C "$root" rev-parse --short HEAD)
  pub=$(mktemp -d)
  if git -C "$root" fetch -q origin pages 2>/dev/null; then
    git -C "$root" worktree add -q --detach "$pub/w" FETCH_HEAD          # the next commit on the branch
  else
    git -C "$root" worktree add -q --detach "$pub/w" HEAD                # the branch's first commit, with no parent
    git -C "$pub/w" checkout -q --orphan site-first
    git -C "$pub/w" rm -rq --cached .
  fi
  find "$pub/w" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -R "$out/." "$pub/w/"
  git -C "$pub/w" add -A
  git -C "$pub/w" commit -qm "Site built from master $src by packages/reckon/tools/site.sh"
  git -C "$pub/w" push -q origin HEAD:refs/heads/pages
  git -C "$root" worktree remove --force "$pub/w"
  echo "site: pushed to pages from $src: https://pages.voltrevo.com/wac-eth/"
fi
