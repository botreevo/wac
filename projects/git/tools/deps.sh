#!/bin/sh
# wac's git, codec, crypto, gzip, wactest and fmt packages, at the commit WAC_COMMIT names, into vendor/wac.
#
#     sh tools/deps.sh          (or: wac task deps)
#
# **Taken from history, not copied in.** wac's root library does not export its `git` package, and a `subdir` import
# cannot reach the sibling packages `git` imports (`codec`, `crypto`, `gzip`), so this server reaches wac's
# sources by relative path. The pinned commit is the single source of truth; vendor/ is gitignored and
# rebuilt from it. When wac exports `git`, this script and vendor/ go, and the imports become `from "wac"`.
#
# The same commit should be the one the `wac` command was built from.
set -eu
cd "$(dirname "$0")/.."
COMMIT=$(tr -d ' \n' < WAC_COMMIT)
# WAC_COMMIT is a commit of wac from before it moved into projects/wac, so it is in this repository's own
# history and the packages come out of it with `git archive` — no network. It is a pin the pin check cannot see
# (it is not a wac.lock entry), so this says so itself when the commit is missing.
top=$(git rev-parse --show-toplevel)
git -C "$top" cat-file -e "$COMMIT^{commit}" 2>/dev/null \
  || { echo "deps: WAC_COMMIT $COMMIT is not in this repository's history" >&2; exit 1; }
rm -rf vendor/wac.fetching && mkdir -p vendor/wac.fetching
git -C "$top" archive "$COMMIT" packages/git/src packages/codec/src packages/crypto/src packages/gzip/src \
  packages/wactest/src packages/fmt/src LICENSE | tar -x -C vendor/wac.fetching
echo "$COMMIT" > vendor/wac.fetching/.commit
rm -rf vendor/wac && mv vendor/wac.fetching vendor/wac
echo "deps: vendor/wac at $COMMIT"
