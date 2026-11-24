#!/bin/sh
# MNIST into example/mnist/data: the four files, checked against their known SHA-256 and unpacked. Not in the
# repository — 11 MB compressed, 55 MB not — so fetched once, from Google's mirror of Yann LeCun's originals.
#
#     sh tools/fetch-mnist.sh
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)/example/mnist/data"
mkdir -p "$dir"
cd "$dir"
base=https://storage.googleapis.com/cvdf-datasets/mnist
while read -r sum file; do
  if [ -f "$file" ]; then continue; fi
  curl -fsSL -o "$file.gz" "$base/$file.gz"
  echo "$sum  $file.gz" | sha256sum -c --quiet -
  gunzip -f "$file.gz"
  echo "fetch-mnist: $file"
done <<'SUMS'
440fcabf73cc546fa21475e81ea370265605f56be210a4024d2ca8f203523609 train-images-idx3-ubyte
3552534a0a558bbed6aed32b30c495cca23d567ec52cac8be1a0730e8010255c train-labels-idx1-ubyte
8d422c7b0a1c1c79245a5bcf07fe86e33eeafee792b84584aec276f5a2dbc4e6 t10k-images-idx3-ubyte
f7ae60f92e00ec6debd23a6088c31dbd2371eca3ffa0defaefb259924204aec6 t10k-labels-idx1-ubyte
SUMS
