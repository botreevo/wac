#!/bin/sh
# wac's git, codec, crypto, gzip, wactest and fmt packages, at the commit WAC_COMMIT names, into vendor/wac.
#
#     sh tools/deps.sh          (or: wac task deps)
#
# **Fetched, not copied in.** wac's root library does not export its `git` package, and a `subdir` import
# cannot reach the sibling packages `git` imports (`codec`, `crypto`, `gzip`), so this server reaches wac's
# sources by relative path. The pinned commit is the single source of truth; vendor/ is gitignored and
# rebuilt from it. When wac exports `git`, this script and vendor/ go, and the imports become `from "wac"`.
#
# The same commit should be the one the `wac` command was built from.
set -eu
cd "$(dirname "$0")/.."
COMMIT=$(tr -d ' \n' < WAC_COMMIT)
URL=${WAC_GIT:-https://git.voltrevo.com/wac.git}
if [ "$(cat vendor/wac/.commit 2>/dev/null)" = "$COMMIT" ]; then echo "deps: vendor/wac is at $COMMIT"; exit 0; fi
rm -rf vendor/wac.fetching && mkdir -p vendor/wac.fetching
git -C vendor/wac.fetching init -q
git -C vendor/wac.fetching fetch -q --depth 1 "$URL" "$COMMIT"
git -C vendor/wac.fetching sparse-checkout set --no-cone /packages/git/src /packages/codec/src /packages/crypto/src /packages/gzip/src /packages/wactest/src /packages/fmt/src /LICENSE >/dev/null
git -C vendor/wac.fetching checkout -q FETCH_HEAD
echo "$COMMIT" > vendor/wac.fetching/.commit
rm -rf vendor/wac.fetching/.git vendor/wac && mv vendor/wac.fetching vendor/wac
echo "deps: vendor/wac at $COMMIT"
