#!/bin/bash
# Fast single-engine benchmark runner (boomkat only, no comparisons)
#
# Usage: ./scripts/run_bench_fast.sh [iterations]
#
# Runs all benchmarks on boomkat, skipping bench_recursion_deep.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
RUNNER="$PROJ_DIR/out/boomkat"
ITERATIONS="${1:-2}"
SKIP="bench_recursion_deep"

if [ ! -f "$RUNNER" ]; then
    echo "ERROR: $RUNNER not found — run: c3c build boomkat"
    exit 1
fi

echo "============================================================"
echo "  Fast Benchmark: boomkat"
echo "  $(date)"
echo "  Iterations: $ITERATIONS"
echo "============================================================"
echo ""

for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    if [ "$name" = "$SKIP" ]; then continue; fi

    total=0
    failed=false
    for ((i = 0; i < ITERATIONS; i++)); do
        start=$(date +%s%N)
        if ! "$RUNNER" "$f" >/dev/null 2>&1; then
            failed=true
            break
        fi
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        total=$((total + elapsed))
    done

    if [ "$failed" = true ]; then
        printf "  %-30s %s\n" "$name" "FAILED"
    else
        avg=$((total / ITERATIONS))
        printf "  %-30s %d ms\n" "$name" "$avg"
    fi
done

echo "============================================================"
