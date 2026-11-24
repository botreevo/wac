#!/bin/sh
# What CI runs for this project (.github/workflows/ci.yml), from this directory, with `wac` on PATH: the
# `wac` this project pins, built by the workflow, and the package cache already filled.
set -eu
cd "$(dirname "$0")/.."
wac task deps
# The browser tests drive Chromium through the Playwright that interop/js pins. A CI runner has the package and
# no browser for it; elsewhere a browser is already there, and a test script has no business installing one.
if [ "${CI:-}" = "true" ]; then (cd interop/js && npx playwright install --with-deps chromium); fi
wac check src
wac task test
