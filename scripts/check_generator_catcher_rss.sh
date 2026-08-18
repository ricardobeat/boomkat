#!/bin/bash
# Regression guard: a generator abandoned while suspended inside a try must not
# cost more memory than the same generator run to exhaustion.
#
# A body that suspends inside a try hands its Catcher chain to the
# GeneratorState, which is its sole owner while the body sleeps. gs_release
# drained the for-in chain but not the catcher chain, so every generator that
# was never resumed leaked one Catcher per try it had entered — and, when a
# finally was routing a throw at the suspend point, the exception object parked
# in Catcher.thrown_val along with it. `var it = g(); it.next();`, the ordinary
# way to take one value from a lazy sequence, leaked on every call.
#
# At 400k abandonments that was ~47.6 MB against ~15.3 MB for the exhausted
# loop, a 3.1x gap; with an Error parked on the chain, ~41.9 MB against ~9.7 MB.
#
# Like the for-in leak this mirrors, it cannot be asserted from inside JS: the
# engine exposes no GC trigger or heap-stat builtin, and neither WeakRef nor
# FinalizationRegistry clears deterministically enough to observe a stranded
# Catcher. Peak RSS is the only reliable signal, so the check lives here.
#
# Semantic coverage of the same paths (throw/return into a suspended try,
# nested try, exception parked across a suspend, for-in and catchers on one
# body) is in test/generator_catcher_cleanup.js.
#
# Usage: ./scripts/check_generator_catcher_rss.sh [path/to/runner]

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${1:-$PROJ_DIR/out/boomkat}"

if [ ! -x "$RUNNER" ]; then
    echo "FAIL: runner not found or not executable: $RUNNER" >&2
    exit 1
fi

# Peak RSS of a leaking abandon-loop grows with the iteration count while the
# exhausted loop stays flat, so the ratio between them is what matters, not an
# absolute byte budget (which would be machine- and allocator-dependent).
# Ceiling of 2.0x: measured 1.0x fixed vs 3.1x leaking, so this sits well
# outside the noise in both directions.
MAX_RATIO_PCT=200
ITERS=400000

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

cat > "$TMPDIR_RUN/exhaust.js" <<EOF
function* g() { try { yield 1; yield 2; } catch (e) {} }
for (var i = 0; i < $ITERS; i++) { var it = g(); it.next(); it.next(); it.next(); }
EOF

cat > "$TMPDIR_RUN/abandon.js" <<EOF
function* g() { try { yield 1; yield 2; } catch (e) {} }
for (var i = 0; i < $ITERS; i++) { var it = g(); it.next(); }
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
abandon_kb=$(measure_rss_kb "$TMPDIR_RUN/abandon.js")

if [ -z "$exhaust_kb" ] || [ -z "$abandon_kb" ] || [ "$exhaust_kb" = "0" ]; then
    echo "FAIL: could not measure peak RSS (needs /usr/bin/time -l)" >&2
    exit 1
fi

ratio_pct=$(( abandon_kb * 100 / exhaust_kb ))

echo "generator exhausted loop : ${exhaust_kb} KB"
echo "generator abandon loop   : ${abandon_kb} KB"
echo "ratio                    : ${ratio_pct}% (ceiling ${MAX_RATIO_PCT}%)"

if [ "$ratio_pct" -gt "$MAX_RATIO_PCT" ]; then
    echo "SOME TESTS FAILED"
    echo "FAIL: abandoning a suspended generator costs ${ratio_pct}% of the exhausted loop's peak RSS." >&2
    echo "      Its Catcher chain is being stranded on the GeneratorState." >&2
    exit 1
fi

echo "generator_catcher_rss: 1 passed, 0 failed"
