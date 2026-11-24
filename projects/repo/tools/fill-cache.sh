#!/bin/sh
# Put every commit the given wac.lock files pin into wac's package cache, and what those pin in turn.
#
#     sh projects/repo/tools/fill-cache.sh projects/<name>/wac.lock…     (default: every tracked wac.lock)
#     sh projects/repo/tools/fill-cache.sh --list [lock…]                the `<url> <commit>` pairs, and nothing else
#
# Each project's own `tools/fill-cache.sh` (eth's `tools/deps.sh`) is this, run on that project's lock.
#
# `wac` resolves a git import only from the cache ($WAC_HOME/cache/git/<escaped url>/<commit>/, complete when it
# holds `pack.pack`), so a fresh machine or CI runner fills it first. A pin into this repository is written
# straight out of local history with `git archive` — the commit is already here, and the pin check
# (projects/repo/cmd/pins.wac) is what makes sure it is. Anything else is fetched with git, falling back to
# git.voltrevo.com for a GitHub URL whose commit GitHub does not have: older pins name repositories that only
# the mirror holds. A dependency's own lock is followed at its `subdir`, so transitive pins are filled too —
# **as well as can be**: a pin only a dependency names may be one nothing here reaches (wac resolves imports as a
# build reaches them, and wac's own lock pins `web` for its site alone), and may name a repository that needs
# credentials, as git.voltrevo.com does from a CI runner. So one of those that cannot be fetched is a warning; a
# pin in a lock given on the command line must be filled, or this fails. A build that does reach a missing one
# stops at it, saying it is not in the cache.
set -eu
top=$(git rev-parse --show-toplevel)
canon=$(sed -n 1p "$top/projects/repo/repository.txt")
cache="${WAC_HOME:-$HOME/.wac}/cache/git"
list=""
if [ "${1:-}" = "--list" ]; then list=1; shift; fi
[ "$#" -gt 0 ] || set -- $(git -C "$top" ls-files | grep -E '(^|/)wac\.lock$' | sed "s|^|$top/|")

norm() { printf '%s' "$1" | sed 's|/*$||; s|\.git$||' | tr 'A-Z' 'a-z'; }

escape() {
  printf '%s' "$1" | od -An -v -tx1 | tr -s ' \n' '  ' | {
    out=""
    for h in $(cat); do
      c=$(printf "\\$(printf '%03o' "0x$h")")
      case "$c" in
        [a-z0-9._-]) out="$out$c" ;;
        [A-Z]) out="$out!$(printf '%s' "$c" | tr 'A-Z' 'a-z')" ;;
        *) out="$out%$(printf '%s' "$h" | tr 'a-f' 'A-F')" ;;
      esac
    done
    printf '%s' "$out"
  }
}

# url commit subdir, one line per import in a lock.
entries() {
  tr '\n' ' ' < "$1" | grep -o '{[^{}]*"git"[^{}]*}' | while IFS= read -r e; do
    url=$(printf '%s' "$e" | sed -n 's/.*"git" *: *"\([^"]*\)".*/\1/p')
    commit=$(printf '%s' "$e" | sed -n 's/.*"commit" *: *"\([0-9a-f]\{40\}\)".*/\1/p')
    sub=$(printf '%s' "$e" | sed -n 's/.*"subdir" *: *"\([^"]*\)".*/\1/p')
    if [ -z "$commit" ]; then echo "fill-cache: $1: $url has no commit; run wac update" >&2; exit 1; fi
    echo "$url $commit ${sub:-.}"
  done
}

fill() {   # lock depth
  entries "$1" | sort -u | while read -r url commit sub; do
    dest="$cache/$(escape "$url")/$commit"
    if [ ! -f "$dest/pack.pack" ]; then
      rm -rf "$dest"; mkdir -p "$dest"
      if [ "$(norm "$url")" = "$(norm "$canon")" ]; then
        git -C "$top" archive "$commit" | tar -x -C "$dest"
      else
        tmp=$(mktemp -d); git -C "$tmp" init -q
        if ! git -C "$tmp" fetch -q --depth 1 "$url" "$commit" 2>/dev/null; then
          mirror=$(printf '%s' "$url" | sed -n 's|^https://github.com/voltrevo/|https://git.voltrevo.com/|p')
          if [ -z "$mirror" ] || ! git -C "$tmp" fetch -q --depth 1 "$mirror" "$commit" 2>/dev/null; then
            rm -rf "$tmp" "$dest"
            if [ "$2" -gt 0 ]; then
              echo "fill-cache: warning: $url $commit, which $1 pins, could not be fetched; left out" >&2
              continue
            fi
            echo "fill-cache: cannot fetch $commit from $url${mirror:+ or $mirror}" >&2; exit 1
          fi
        fi
        git -C "$tmp" archive "$commit" | tar -x -C "$dest"
        rm -rf "$tmp"
      fi
      touch "$dest/pack.pack"     # the cache's "this checkout is complete" marker
      echo "fill-cache: $url $commit"
    fi
    inner="$dest/${sub#./}/wac.lock"
    if [ -f "$inner" ]; then fill "$inner" $(($2 + 1)); fi
  done
}

if [ -n "$list" ]; then
  for lock in "$@"; do entries "$lock"; done | while read -r url commit sub; do echo "$url $commit"; done | sort -u
  exit 0
fi
for lock in "$@"; do fill "$lock" 0; done
