#!/bin/bash
# TinyDuck performance benchmark suite
#
# Measures: binary size, execution time, peak RSS memory
# Usage: bash scripts/run_benchmarks.sh [label]
#
# The optional label (e.g. "bytecode" or "treewalk") is printed in the header
# and used to distinguish baseline vs. after runs.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
ENGINE="$PROJ_DIR/out/tinyduck_test"
LABEL="${1:-current}"

# ── Helpers ──────────────────────────────────────────────────────────────────

measure_time_ms() {
    local exe="$1" script="$2"
    if [ ! -f "$exe" ]; then echo "N/A"; return; fi
    if [ ! -f "$script" ]; then echo "N/A"; return; fi

    local start_ns end_ns elapsed_ns
    start_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
    "$exe" "$script" >/dev/null 2>&1 || true
    end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
    elapsed_ns=$(( end_ns - start_ns ))
    echo $(( elapsed_ns / 1000000 ))
}

measure_rss_kb() {
    local exe="$1" script="$2"
    if [ ! -f "$exe" ]; then echo "N/A"; return; fi
    if [ ! -f "$script" ]; then echo "N/A"; return; fi

    local output
    output=$(/usr/bin/time -l "$exe" "$script" 2>&1 >/dev/null) || true
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)
    if [ -z "$rss_bytes" ]; then echo "N/A"; return; fi
    echo $(( rss_bytes / 1024 ))
}

# ── Binary sizes ─────────────────────────────────────────────────────────────

echo "============================================================"
echo "  TinyDuck Benchmark Suite"
echo "  Label: $LABEL"
echo "  Date: $(date)"
echo "============================================================"
echo ""

echo "── Binary Sizes (stripped) ──"
echo ""

for bin in tinyduck_test tinyduck_test_noregexp tinyduck; do
    path="$PROJ_DIR/out/$bin"
    if [ -f "$path" ]; then
        strip "$path" 2>/dev/null || true
        size_bytes=$(wc -c < "$path" | tr -d ' ')
        size_kb=$(( size_bytes / 1024 ))
        printf "  %-24s %6d KB\n" "$bin" "$size_kb"
    else
        printf "  %-24s %6s\n" "$bin" "N/A"
    fi
done
echo ""

# ── Performance benchmarks ───────────────────────────────────────────────────

BENCH_SCRIPTS=(
    "bench_loop.js           Arithmetic loop (100k)"
    "bench_recursion.js      Recursive fib(20)"
    "bench_function_call.js  Function calls (100k)"
    "bench_object.js         Object property (500k)"
    "bench_array.js          Array ops (10k push+read)"
    "bench_string.js         String concat (5k)"
    "bench_closure.js        Closures (100k calls)"
    "bench_mixed.js          Mixed workload"
    "memory_test.js          Memory stress (5k obj)"
)

printf "%-30s  %8s  %8s\n" "Benchmark" "Time(ms)" "RSS(KB)"
printf "%-30s  %8s  %8s\n" "---" "---" "---"

for entry in "${BENCH_SCRIPTS[@]}"; do
    script_name="${entry%% *}"
    description="${entry#* }"
    script_path="$BENCH_DIR/$script_name"

    time_ms=$(measure_time_ms "$ENGINE" "$script_path")
    rss_kb=$(measure_rss_kb "$ENGINE" "$script_path")

    printf "%-30s  %8s  %8s\n" "$description" "$time_ms" "$rss_kb"
done

echo ""
echo "============================================================"
