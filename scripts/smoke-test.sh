#!/usr/bin/env bash
# smoke-test.sh — run the real-world-corpus AST-preservation smoke test.
#
# Reads tests/corpus/smoke_sample.toml (default) or the sample passed via
# --sample. Exits non-zero on any regression. See scripts/smoke_test.jl
# for full flag documentation.

set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec julia --project="$REPO/corpus/minimizer" "$REPO/scripts/smoke_test.jl" "$@"
