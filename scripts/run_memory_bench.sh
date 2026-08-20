#!/bin/bash
# Memory usage benchmark: peak RSS comparison across engines.
#
# Usage: ./scripts/run_memory_bench.sh [script.js]
#
# Compares: boomkat, original Duktape (duktape), QuickJS (qjs)
# Measures peak RSS via /usr/bin/time -l (macOS) or /usr/bin/time -v (Linux).

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
C3_RUNNER="$PROJ_DIR/out/boomkat"
ORIG="$PROJ_DIR/out/duktape"
QJS="$PROJ_DIR/out/qjs"

# ── Helpers ──────────────────────────────────────────────────────────────────

measure_rss_kb() {
    local exe="$1"
    local script="$2"
    if [ ! -f "$exe" ]; then echo "N/A"; return; fi
    if [ ! -f "$script" ]; then echo "N/A"; return; fi

    local output
    output=$(/usr/bin/time -l "$exe" "$script" 2>&1 >/dev/null) || true
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)
    if [ -z "$rss_bytes" ]; then echo "N/A"; return; fi
    echo $(( rss_bytes / 1024 ))
}

ratio() {
    local a="$1" b="$2"
    if [ "$a" = "N/A" ] || [ "$b" = "N/A" ] || [ "$b" = "0" ]; then echo "N/A"; return; fi
    echo "scale=1; $a / $b" | bc 2>/dev/null || echo "?"
}

print_table() {
    local sname="$1" c3_rss="$2" orig_rss="$3" qjs_rss="$4"

    local c3_ratio=$(ratio "$c3_rss" "$qjs_rss")
    local orig_ratio=$(ratio "$orig_rss" "$qjs_rss")
    local qjs_ratio="1.0"

    local c3_label="$c3_rss KB"
    local orig_label="$orig_rss KB"
    local qjs_label="$qjs_rss KB"
    [ "$c3_rss" = "N/A" ] && c3_label="N/A"
    [ "$orig_rss" = "N/A" ] && orig_label="N/A"
    [ "$qjs_rss" = "N/A" ] && qjs_label="N/A"

    local header="Engine ($sname)"
    local col1=${#header}
    [ $col1 -lt 24 ] && col1=24

    local hbar=$(printf '%*s' "$col1" '' | tr ' ' '-')

    printf "  %-${col1}s   %-9s   %-8s\n" "$header" "Peak RSS" "vs QJS"
    echo "  ${hbar}---${hbar:0:11}---${hbar:0:10}"
    printf "  %-${col1}s   %9s   %7sx\n" "boomkat" "$c3_label" "$c3_ratio"
    printf "  %-${col1}s   %9s   %7sx\n" "duktape (Duktape v2.7.0)" "$orig_label" "$orig_ratio"
    printf "  %-${col1}s   %9s   %7sx\n" "qjs (QuickJS)" "$qjs_label" "$qjs_ratio"
    echo ""
}

# ── Scripts to test ──────────────────────────────────────────────────────────

SCRIPTS=(
    "$BENCH_DIR/memory_test.js"
    "$BENCH_DIR/bench_memory_heavy.js"
)

# ── Run ──────────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  Memory Usage Benchmark"
echo "  $(date)"
echo "============================================================"
echo ""

for script in "${SCRIPTS[@]}"; do
    sname=$(basename "$script")

    c3_rss=$(measure_rss_kb "$C3_RUNNER" "$script")
    orig_rss=$(measure_rss_kb "$ORIG" "$script")
    qjs_rss=$(measure_rss_kb "$QJS" "$script")

    print_table "$sname" "$c3_rss" "$orig_rss" "$qjs_rss"
done

echo "============================================================"
