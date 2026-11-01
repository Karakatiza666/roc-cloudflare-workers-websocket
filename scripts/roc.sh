#!/usr/bin/env bash
# Runs roc under a memory cap. ROC: the compiler (default: the nightly that the platform pins, from its
# bench/get-roc.sh). PLATFORM: the cloudflare-workers checkout (default ../cloudflare-workers-ws).
here="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${PLATFORM:-$here/../cloudflare-workers-ws}"
ROC="${ROC:-$("$PLATFORM/bench/get-roc.sh")}"
exec systemd-run --user --scope --quiet -p MemoryMax=16G -p MemorySwapMax=0 --setenv=XDG_CACHE_HOME=$HOME/.cache/roc-cfw-adapter "$ROC" "$@"
