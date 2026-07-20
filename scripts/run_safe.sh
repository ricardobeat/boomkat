#!/usr/bin/env bash
# Run a JS file through duktape_c3 with timeout and RSS limit.
# Usage: bash scripts/run_safe.sh <js-file> [--timeout N] [--memlimit MB]
# Default: 10s timeout, 2048 MB RSS limit (SIGKILL on exceed).
set -uo pipefail
file="${1:?usage: run_safe.sh <file> [--timeout N] [--memlimit MB]}"
shift
timeout_s=10
memlimit_mb=2048
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)  timeout_s="$2"; shift 2 ;;
        --memlimit) memlimit_mb="$2"; shift 2 ;;
        *) echo "unknown flag: $1"; exit 1 ;;
    esac
done
ulimit_v=$((memlimit_mb * 1024))
ulimit -v "$ulimit_v" 2>/dev/null || true
timeout "$timeout_s" ./out/duktape_c3 "$file" 2>/dev/null
rc=$?
if   [ "$rc" -eq 124 ]; then echo "TIMEOUT ($timeout_s s)"
elif [ "$rc" -eq 137 ]; then echo "MEMKILL ($memlimit_mb MB)"
elif [ "$rc" -eq 139 ]; then echo "SIGSEGV"
elif [ "$rc" -eq 133 ]; then echo "SIGABRT"
elif [ "$rc" -eq 0   ]; then echo "PASS"
else                          echo "FAIL (rc=$rc)"
fi
exit "$rc"
