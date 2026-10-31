#!/usr/bin/env bash
# Runs roc under a memory cap. ROC: the compiler (default: the nightly that talon's tooling pins).
ROC="${ROC:-$HOME/dev/Karakatiza666/talon/cloudflare-workers/.cache/nightlies/nightly-2026-10-26-3c0fffe/roc}"
exec systemd-run --user --scope --quiet -p MemoryMax=16G -p MemorySwapMax=0 --setenv=XDG_CACHE_HOME=$HOME/.cache/roc-cfw-adapter "$ROC" "$@"
