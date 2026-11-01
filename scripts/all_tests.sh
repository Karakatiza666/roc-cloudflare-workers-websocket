#!/usr/bin/env bash
# The local checks. Usage: scripts/all_tests.sh [--no-run]
# Env: ROC (default: the nightly that roc-websocket pins, see scripts/roc.sh), PLATFORM (the cloudflare-workers
# checkout whose platform/main.roc the headers name, default ../cloudflare-workers-ws), MINIFLARE.
# fmt, check and test the package; check and build each example to wasm32; then run each example in Miniflare with
# real WebSocket clients and servers (tests/run.mjs, tests/checks-<example>.mjs).
set -euo pipefail
cd "$(dirname "$0")/.."
roc=scripts/roc.sh
"$roc" version
"$roc" fmt --check src examples
"$roc" check src/main.roc
"$roc" test src/main.roc
mkdir -p .cache/out
for name in client server room; do
	"$roc" check "examples/$name.roc"
	"$roc" build --target=wasm32 --no-cache --output=".cache/out/$name.wasm" "examples/$name.roc"
done
if [[ "${1:-}" != "--no-run" ]]; then
	for name in client server room; do
		node tests/run.mjs "$name" ".cache/out/$name.wasm"
	done
fi
echo "ALL PASS"
