#!/bin/bash
# Compatibility entry point: JSON on stdout, progress on stderr.
set -euo pipefail
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$PROJ_DIR/scripts/run_benchmarks.py" "$@"
