#!/bin/sh
# What CI runs for this project (.github/workflows/ci.yml), from this directory, with `wac` on PATH: the
# `wac` this project pins, built by the workflow, and the package cache already filled.
set -eu
cd "$(dirname "$0")/.."
# The suite's ordinary lane, as the gate runs it, without the push.
wac run --allow-read --allow-write --allow-run --allow-env --allow-net tools/runTests.wac --
