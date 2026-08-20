#!/bin/bash
# Benchmark comparison runner for Boomkat vs original Duktape vs QuickJS
#
# Usage: ./scripts/run_benchmarks.sh [iterations]
#
# Runs all benchmarks on all engines and prints a comparison table.
# Results for duktape and qjs are cached in out/bench_cache_*.txt
# and reused across runs. Delete those files to force a re-run.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
C3_RUNNER="$PROJ_DIR/out/boomkat"
ORIG="$PROJ_DIR/out/duktape"
QJS="$PROJ_DIR/out/qjs"
ITERATIONS="${1:-3}"
CACHE_DIR="$PROJ_DIR/out"
CACHE_ORIG="$CACHE_DIR/bench_cache_duktape.txt"
CACHE_QJS="$CACHE_DIR/bench_cache_qjs.txt"

TMPDIR_BENCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BENCH"' EXIT

if [ ! -f "$C3_RUNNER" ]; then
    echo "ERROR: C3 runner not found at $C3_RUNNER"
    echo "Run: c3c build boomkat"
    exit 1
fi

if [ ! -f "$ORIG" ]; then
    echo "ERROR: Original duktape not found at $ORIG"
    exit 1
fi

# QuickJS is optional — skip its section if not built
QJS_AVAILABLE=false
if [ -f "$QJS" ]; then
    QJS_AVAILABLE=true
fi

# ── Cache helpers ───────────────────────────────────────────────────────────

cache_get() {
    local file="$1" key="$2"
    if [ -f "$file" ]; then
        grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2
    fi
}

cache_set() {
    local file="$1" key="$2" val="$3"
    if [ -f "$file" ]; then
        # remove old entry if present
        grep -v "^${key}=" "$file" > "${file}.tmp" 2>/dev/null || true
        mv "${file}.tmp" "$file"
    fi
    echo "${key}=${val}" >> "$file"
}

# Check if all benchmarks are cached for a given cache file
all_cached() {
    local file="$1"
    if [ ! -f "$file" ]; then return 1; fi
    for f in "$BENCH_DIR"/bench_*.js; do
        local name=$(basename "$f" .js)
        local val=$(cache_get "$file" "$name")
        if [ -z "$val" ]; then return 1; fi
    done
    return 0
}

echo "============================================================"
echo "  Boomkat — Benchmark Comparison"
echo "  $(date)"
echo "  Iterations per benchmark: $ITERATIONS"
[ "$QJS_AVAILABLE" = true ] && echo "  QuickJS: available" || echo "  QuickJS: not built (run 'just build-quickjs')"
echo "============================================================"
echo ""

# High-resolution timing helper (nanoseconds → milliseconds)
time_ms() {
    local start end elapsed_ms
    start=$(date +%s%N)
    "$@" >/dev/null 2>&1
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    echo "$elapsed_ms"
}

echo "------------------------------------------------------------"
echo "  1. boomkat (compile + execute)"
echo "------------------------------------------------------------"
for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    echo -n "  $name ... "
    total=0
    count=0
    failed=false
    for ((i=0; i<ITERATIONS; i++)); do
        ms=$(time_ms "$C3_RUNNER" "$f")
        if [ $? -ne 0 ]; then failed=true; break; fi
        total=$((total + ms))
        count=$((count + 1))
    done
    if [ "$failed" = true ] || [ $count -eq 0 ]; then
        echo "FAILED"
        echo "N/A" > "$TMPDIR_BENCH/c3_$name"
    else
        avg=$((total / count))
        echo "$avg" > "$TMPDIR_BENCH/c3_$name"
        echo "${avg}ms"
    fi
done

echo ""
echo "------------------------------------------------------------"
echo "  2. Original Duktape v2.7.0 (compile + execute)"
echo "------------------------------------------------------------"
if all_cached "$CACHE_ORIG"; then
    echo "  (using cached results — delete $CACHE_ORIG to re-run)"
    for f in "$BENCH_DIR"/bench_*.js; do
        name=$(basename "$f" .js)
        val=$(cache_get "$CACHE_ORIG" "$name")
        echo "$val" > "$TMPDIR_BENCH/orig_$name"
        echo "  $name ... ${val}ms (cached)"
    done
else
    for f in "$BENCH_DIR"/bench_*.js; do
        name=$(basename "$f" .js)
        echo -n "  $name ... "
        total=0
        count=0
        for ((i=0; i<ITERATIONS; i++)); do
            ms=$(time_ms "$ORIG" "$f")
            total=$((total + ms))
            count=$((count + 1))
        done
        avg=$((total / count))
        echo "$avg" > "$TMPDIR_BENCH/orig_$name"
        cache_set "$CACHE_ORIG" "$name" "$avg"
        echo "${avg}ms"
    done
fi

if [ "$QJS_AVAILABLE" = true ]; then
    echo ""
    echo "------------------------------------------------------------"
    echo "  3. QuickJS (compile + execute)"
    echo "------------------------------------------------------------"
    if all_cached "$CACHE_QJS"; then
        echo "  (using cached results — delete $CACHE_QJS to re-run)"
        for f in "$BENCH_DIR"/bench_*.js; do
            name=$(basename "$f" .js)
            val=$(cache_get "$CACHE_QJS" "$name")
            echo "$val" > "$TMPDIR_BENCH/qjs_$name"
            echo "  $name ... ${val}ms (cached)"
        done
    else
        for f in "$BENCH_DIR"/bench_*.js; do
            name=$(basename "$f" .js)
            echo -n "  $name ... "
            total=0
            count=0
            for ((i=0; i<ITERATIONS; i++)); do
                ms=$(time_ms "$QJS" "$f")
                total=$((total + ms))
                count=$((count + 1))
            done
            avg=$((total / count))
            echo "$avg" > "$TMPDIR_BENCH/qjs_$name"
            cache_set "$CACHE_QJS" "$name" "$avg"
            echo "${avg}ms"
        done
    fi
fi

echo ""
echo "============================================================"
echo "  Results Summary"
echo "============================================================"
echo ""

# Collect benchmark names in order
bench_names=()
for f in "$BENCH_DIR"/bench_*.js; do
    bench_names+=("$(basename "$f" .js)")
done

if [ "$QJS_AVAILABLE" = true ]; then
    printf "  %-30s %12s %12s %12s %8s\n" "Benchmark" "boomkat(ms)" "Duktape(ms)" "QuickJS(ms)" "Ratio"
    echo "  --------------------------------------------------------------------------"
    for name in "${bench_names[@]}"; do
        c3_val=$(cat "$TMPDIR_BENCH/c3_$name")
        orig_val=$(cat "$TMPDIR_BENCH/orig_$name")
        qjs_val=$(cat "$TMPDIR_BENCH/qjs_$name")

        if [ "$c3_val" != "N/A" ] && [ "$orig_val" != "N/A" ]; then
            ratio=$(echo "scale=2; $c3_val / $orig_val" | bc 2>/dev/null || echo "?")
            if [ "$(echo "$ratio > 0" | bc 2>/dev/null)" = "1" ]; then
                printf "  %-30s %7.0fms %7.0fms %7.0fms %8.1fx\n" "$name" "$c3_val" "$orig_val" "$qjs_val" "$ratio"
            else
                printf "  %-30s %7.0fms %7.0fms %7.0fms %8s\n" "$name" "$c3_val" "$orig_val" "$qjs_val" "?"
            fi
        elif [ "$c3_val" != "N/A" ] && [ "$qjs_val" != "N/A" ]; then
            ratio=$(echo "scale=2; $c3_val / $qjs_val" | bc 2>/dev/null || echo "?")
            if [ "$(echo "$ratio > 0" | bc 2>/dev/null)" = "1" ]; then
                printf "  %-30s %7.0fms %8s %7.0fms %8.1fx\n" "$name" "$c3_val" "-" "$qjs_val" "$ratio"
            else
                printf "  %-30s %7.0fms %8s %7.0fms %8s\n" "$name" "$c3_val" "-" "$qjs_val" "?"
            fi
        elif [ "$orig_val" != "N/A" ] && [ "$qjs_val" != "N/A" ]; then
            printf "  %-30s %8s %7.0fms %7.0fms %8s\n" "$name" "-" "$orig_val" "$qjs_val" "?"
        else
            printf "  %-30s %10s %10s %10s %8s\n" "$name" "$c3_val" "$orig_val" "$qjs_val" "-"
        fi
    done
else
    printf "  %-30s %12s %12s %10s\n" "Benchmark" "boomkat(ms)" "Duktape(ms)" "Ratio"
    echo "  -------------------------------------------------------------"
    for name in "${bench_names[@]}"; do
        c3_val=$(cat "$TMPDIR_BENCH/c3_$name")
        orig_val=$(cat "$TMPDIR_BENCH/orig_$name")
        if [ "$c3_val" != "N/A" ] && [ "$orig_val" != "N/A" ]; then
            ratio=$(echo "scale=2; $c3_val / $orig_val" | bc 2>/dev/null || echo "?")
            if [ "$(echo "$ratio > 0" | bc 2>/dev/null)" = "1" ]; then
                printf "  %-30s %7.0fms %7.0fms %8.1fx\n" "$name" "$c3_val" "$orig_val" "$ratio"
            else
                printf "  %-30s %7.0fms %7.0fms %8s\n" "$name" "$c3_val" "$orig_val" "?"
            fi
        else
            printf "  %-30s %10s %10s %10s\n" "$name" "$c3_val" "$orig_val" "-"
        fi
    done
fi
echo "  -------------------------------------------------------------"
echo ""
if [ "$QJS_AVAILABLE" = true ]; then
    echo "Ratio (boomkat/Duktape) > 1.0 means boomkat is slower."
else
    echo "Ratio > 1.0 means boomkat is slower (higher is worse)."
fi
echo "============================================================"
