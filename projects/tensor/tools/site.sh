#!/bin/sh
# The static site, assembled in dist/site: the landing page, the draw-a-digit demo and the CPU-vs-GPU benchmark,
# each page with the weights it loads. The MNIST data itself is left out — 55 MB — so the demo offers no training.
#
#     sh tools/site.sh
set -eu
cd "$(dirname "$0")/.."
out=dist/site
rm -rf "$out"
mkdir -p "$out"
cp site/index.html "$out/"
wac run --allow-read --allow-write --allow-run tools/build.wac example/mnist/page.wac dist/site-mnist --title "Draw a digit"
wac run --allow-read --allow-write --allow-run tools/build.wac example/bench.wac dist/site-bench --title "wac-tensor: CPU vs GPU"
for page in mnist bench; do
  mkdir -p "$out/$page"
  cp "dist/site-$page/index.html" "$out/$page/"
  cp example/mnist/mnist.weights "$out/$page/"
done
echo "site: $out"
