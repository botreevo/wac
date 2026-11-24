#!/bin/sh
# What CI runs for wac (.github/workflows/ci.yml): the suite's ordinary lane, as tools/push.sh runs it, on a machine
# made into a gate machine first. `wac` on PATH is this checkout's, built by the workflow, and the package cache is
# filled.
#
# The gate assumes what the shared machine already has — tools/gatedeps.sh lists the packages, and the gate builds
# the native host the suite runs (`wac task seed`), the wasmtime host and the Rust assembler. On a CI runner (CI=true)
# this installs and builds them; anywhere else it only asks gatedeps, and stops if the machine falls short, rather
# than installing anything on somebody's computer.
set -eu
cd "$(dirname "$0")/.."
if [ "${CI:-}" = "true" ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq coturn iproute2 openssh-client openssh-server >/dev/null
  sudo mkdir -p /run/sshd
  pip install -q aioice aiortc google-crc32c
  deno run -A npm:playwright@1 install --with-deps chromium
  (cd site && npm ci --no-audit --no-fund)
  (cd bootstrap/rust && cargo build --release --quiet)
  bash bootstrap.sh --host v8 --no-install          # native/v8/target/release/wac: what the suite runs, and the seed
  mkdir -p native/seed && cp native/v8/seed/wacc.wasm native/seed/wacc.wasm
  (cd native && cargo build --release --quiet)       # the wasmtime host, for the two-host tests
fi
bash tools/gatedeps.sh
./native/v8/target/release/wac run --allow-read --allow-write --allow-run --allow-env --allow-net tools/runTests.wac --
