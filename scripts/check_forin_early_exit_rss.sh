#!/bin/bash
# Regression guard: a for-in loop exited early must not cost more memory than
# the same loop run to exhaustion.
#
# The enumeration state (key snapshot + a temproot pin on the target) used to
# be released only on the exhausted path, so `for (k in o) break;` — the
# standard "is this object non-empty" idiom — leaked one state per iteration
# and pinned every enumerated object forever. At 200k iterations that was
# ~112 MB against ~3.7 MB for the exhausted loop, a 30x gap.
#
# This cannot be asserted from inside JS: the engine exposes no GC trigger or
# heap-stat builtin, and neither WeakRef nor FinalizationRegistry clears
# deterministically enough to observe the stranded pin. Peak RSS is the only
# reliable signal, so the check lives here rather than in test/.
#
# Semantic coverage of the same exit paths (break, return, throw, labeled
# break/continue, nested, proxy, generator suspend/abandon) is in
# test/forin_early_exit_cleanup.js.
#
# Usage: ./scripts/check_forin_early_exit_rss.sh [path/to/runner]

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${1:-$PROJ_DIR/out/duktape_c3}"

if [ ! -x "$RUNNER" ]; then
    echo "FAIL: runner not found or not executable: $RUNNER" >&2
    exit 1
fi

# Peak RSS of a leaking break-loop grows with the iteration count while the
# exhausted loop stays flat, so the ratio between them is what matters, not an
# absolute byte budget (which would be machine- and allocator-dependent).
# Ceiling of 2.0x: measured 1.0x fixed vs 30x leaking, so this is far outside
# the noise in both directions.
MAX_RATIO_PCT=200
ITERS=200000

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

cat > "$TMPDIR_RUN/exhaust.js" <<EOF
var o = { a: 1, b: 2, c: 3 };
for (var i = 0; i < $ITERS; i++) { for (var k in o) {} }
EOF

cat > "$TMPDIR_RUN/early.js" <<EOF
var o = { a: 1, b: 2, c: 3 };
for (var i = 0; i < $ITERS; i++) { for (var k in o) break; }
EOF

measure_rss_kb() {
    local script="$1"
    local output
    output=$(/usr/bin/time -l "$RUNNER" "$script" 2>&1 >/dev/null) || true
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)
    if [ -z "$rss_bytes" ]; then echo ""; return; fi
    echo $(( rss_bytes / 1024 ))
}

exhaust_kb=$(measure_rss_kb "$TMPDIR_RUN/exhaust.js")
early_kb=$(measure_rss_kb "$TMPDIR_RUN/early.js")

if [ -z "$exhaust_kb" ] || [ -z "$early_kb" ] || [ "$exhaust_kb" = "0" ]; then
    echo "FAIL: could not measure peak RSS (needs /usr/bin/time -l)" >&2
    exit 1
fi

ratio_pct=$(( early_kb * 100 / exhaust_kb ))

echo "for-in exhausted loop : ${exhaust_kb} KB"
echo "for-in break loop     : ${early_kb} KB"
echo "ratio                 : ${ratio_pct}% (ceiling ${MAX_RATIO_PCT}%)"

if [ "$ratio_pct" -gt "$MAX_RATIO_PCT" ]; then
    echo "SOME TESTS FAILED"
    echo "FAIL: breaking out of a for-in costs ${ratio_pct}% of the exhausted loop's peak RSS." >&2
    echo "      Enumeration state is being stranded on an early-exit path." >&2
    exit 1
fi

echo "forin_early_exit_rss: 1 passed, 0 failed"
