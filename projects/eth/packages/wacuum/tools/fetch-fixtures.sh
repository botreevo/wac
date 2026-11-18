#!/bin/sh
# Fetch execution-specs' test fixtures into fixtures/ (gitignored), for the forks this client runs: the state,
# blockchain and engine tests for Cancun, Prague, Osaka and Amsterdam, and every timed transition between them.
# About 1 GB to fetch, streamed (nothing is kept but what is unpacked), and about 11 GB unpacked.
#
#     sh tools/fetch-fixtures.sh
#
# The release is pinned, and checked by its SHA-256, so a pass count means the same thing tomorrow. The pin is the
# release go-ethereum's latest release tests against: its build/checksums.txt names it on its `# version:spec-tests`
# line, with the archive's hash below. To move it, read that file at geth's newest tag (the Go module proxy has it:
# `go mod download -json github.com/ethereum/go-ethereum@latest`, then build/checksums.txt in the directory it
# names), set `version` and `sha256` here to what it says, and run the gate. Before 2026-11-18 this was
# execution-spec-tests v5.4.0, which lacked tests that caught a mainnet bug (a CREATE refused for its balance
# warmed its address): tests@v21.0.1, geth 1.17.10's, found it.
set -eu
version=tests@v21.0.1
sha256=b9b14391ed1a625e4ca9a058c055d0eacd98a42b76c7a6127c640cdc2d3c9439
forks="cancun prague osaka amsterdam"
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/fixtures"
cd "$root/fixtures"
if [ -f .version ] && [ "$(cat .version)" = "$version $forks" ]; then echo "fixtures $version already here"; exit 0; fi
patterns=""
for kind in state_tests blockchain_tests blockchain_tests_engine; do
  for f in $forks; do patterns="$patterns fixtures/$kind/for_$f/*"; done
  patterns="$patterns fixtures/$kind/for_*attime15k/*"
done
url="https://github.com/ethereum/execution-specs/releases/download/$(echo "$version" | sed 's/@/%40/')/fixtures.tar.gz"
# The archive is hashed as it streams past, and what was unpacked is thrown away if the hash is not the pin's.
fifo=$(mktemp -u)
mkfifo "$fifo"
sha256sum < "$fifo" > .hash &
curl -fsSL "$url" | tee "$fifo" | tar -xz --strip-components=1 --wildcards $patterns
wait
rm -f "$fifo"
if [ "$(cut -d' ' -f1 .hash)" != "$sha256" ]; then
  echo "fetch-fixtures: $url is not the pinned archive ($(cut -d' ' -f1 .hash))" >&2
  rm -rf state_tests blockchain_tests blockchain_tests_engine .hash
  exit 1
fi
rm .hash
echo "$version $forks" > .version
echo "fixtures $version in $root/fixtures"
