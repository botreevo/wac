#!/bin/sh
# dist/devnet: the node, site and faucet as one executable file, which runs on the `wac` it finds on PATH.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
wac app --allow-read --allow-write --allow-net cmd/devnet.wac -o dist/devnet
