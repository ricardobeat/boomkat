#!/bin/bash
# ES6+ benchmark comparison: boomkat vs QuickJS.
#
# Usage: ./scripts/run_bench_es6.sh [iterations]
#
# Duktape is ES5.1 and cannot parse these, so it is not in the table. See
# benchmarks/es6/README.md for why this tier exists separately.
#
# Runs the two engines ALTERNATING and reports best-of-N, for the same reason
# scripts/perf_diff.sh does: machine load drifts over minutes, and running one
# engine to completion then the other attributes that drift to the engine.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks/es6"
BK="$PROJ_DIR/out/boomkat"
QJS="$PROJ_DIR/out/qjs"
ITERATIONS="${1:-3}"

[ -x "$BK" ]  || { echo "ERROR: $BK not found — run: just build boomkat" >&2; exit 1; }
[ -x "$QJS" ] || { echo "ERROR: $QJS not found — QuickJS is required for this tier" >&2; exit 1; }

LOAD=$(uptime | sed 's/.*averages*: *//' | awk '{print $1}')
if awk -v l="$LOAD" 'BEGIN{exit !(l>3.0)}'; then
    echo "WARNING: load average is $LOAD; treat these numbers as relative only." >&2
    echo >&2
fi

run_best() {
    local bin="$1" file="$2" best=999
    for _ in $(seq "$ITERATIONS"); do
        local t
        t=$( { /usr/bin/time -p "$bin" "$file" >/dev/null; } 2>&1 | awk '/^real/{print $2}' ) || continue
        best=$(awk -v a="$t" -v c="$best" 'BEGIN{print (a<c)?a:c}')
    done
    echo "$best"
}

printf "%-26s %10s %10s %9s\n" "benchmark" "boomkat" "quickjs" "ratio"
printf "%-26s %10s %10s %9s\n" "--------------------------" "----------" "----------" "---------"

total_bk=0; total_qjs=0
for f in "$BENCH_DIR"/bench_*.js; do
    name="$(basename "$f" .js | sed 's/^bench_//')"
    b=$(run_best "$BK" "$f")
    q=$(run_best "$QJS" "$f")
    ratio=$(awk -v b="$b" -v q="$q" 'BEGIN{ if (q==0) print "n/a"; else printf "%.1fx", b/q }')
    printf "%-26s %9ss %9ss %9s\n" "$name" "$b" "$q" "$ratio"
    total_bk=$(awk -v a="$total_bk" -v b="$b" 'BEGIN{print a+b}')
    total_qjs=$(awk -v a="$total_qjs" -v q="$q" 'BEGIN{print a+q}')
done

printf "%-26s %9ss %9ss %9s\n" "TOTAL" "$total_bk" "$total_qjs" \
    "$(awk -v b="$total_bk" -v q="$total_qjs" 'BEGIN{ if (q==0) print "n/a"; else printf "%.1fx", b/q }')"
echo
echo "ratio > 1.0 means boomkat is slower. Best of $ITERATIONS, alternating engines."
