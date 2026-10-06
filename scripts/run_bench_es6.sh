#!/bin/bash
# ES6 JSON producer: same options as run_benchmarks.py.
set -euo pipefail
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$PROJ_DIR/scripts/run_benchmarks.py" --suite es6 "$@"
