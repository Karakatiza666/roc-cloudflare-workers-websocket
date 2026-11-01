#!/usr/bin/env bash
# The local and CI checks. Usage: ROC=/path/to/roc scripts/all_tests.sh [--no-run]
# Env: ROC (default: roc; CI installs the nightly of .roc-version), PLATFORM and MINIFLARE (see tests/run.mjs).
# fmt, check and test the package; check and build each example to wasm32; then run each example in Miniflare with
# real WebSocket clients and servers (tests/run.mjs, tests/checks-<example>.mjs). Miniflare is the one of a global
# wrangler (npm install -g wrangler); the platform's JS shim is the js/ of the platform bundle that roc check downloads.
set -euo pipefail
ROC="${ROC:-roc}"
cd "$(dirname "$0")/.."
# Keep the build cache inside the repository.
export ROC_CACHE_DIR="${ROC_CACHE_DIR:-$PWD/.cache/roc}"
mkdir -p "$ROC_CACHE_DIR" .cache/out

"$ROC" version
"$ROC" fmt --check src examples
"$ROC" check src/main.roc
"$ROC" test src/main.roc
for name in client server room; do
	"$ROC" check "examples/$name.roc"
	"$ROC" build --target=wasm32 --no-cache --output=".cache/out/$name.wasm" "examples/$name.roc"
done
if [[ "${1:-}" != "--no-run" ]]; then
	for name in client server room; do
		node tests/run.mjs "$name" ".cache/out/$name.wasm"
	done
fi
"$ROC" docs src/main.roc --output="$ROC_CACHE_DIR/docs" >/dev/null
echo "ALL PASS"
