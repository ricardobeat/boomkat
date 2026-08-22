#!/bin/bash
# Drive many Heap.reset() cycles with the engine's reset-crossing caches
# populated, under ASAN.
#
# reset() is reachable only from the test262 worker loop, never from JS, so no
# ordinary test can exercise it. That makes a stale-pointer bug in a cache that
# outlives the reset invisible to every other lane: it passes standalone, passes
# the conformance suite, and passes GC_STRESS with ASAN, then shows up only as
# widespread MEMKILL in a full corpus run where each affected test still passes
# under --single. Feeding the same test repeatedly to `--worker` reproduces that
# boundary directly -- one reset per line of input -- in seconds instead of a
# 40-minute corpus run.
#
# Usage: bash scripts/run_heap_reset.sh [cycles] [test.js]
# Returns non-zero if any cycle fails.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CYCLES="${1:-40}"
TEST="${2:-test/heap_reset_lifetime.js}"
RUNNER="$ROOT/out/test262_runner_asan"

if [ ! -x "$RUNNER" ]; then
    echo "ERROR: $RUNNER not found. Build it with: make out/test262_runner_asan" >&2
    exit 2
fi

cd "$ROOT"
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
for _ in $(seq "$CYCLES"); do echo "$TEST"; done > "$LIST"

OUT=$("$RUNNER" --worker < "$LIST" 2>&1)
STATUS=$?

# The worker prints one PASS/FAIL line per input line. Anything short of
# CYCLES passes means a reset cycle degraded the engine, which is exactly the
# signal this lane exists to catch.
PASSES=$(printf '%s\n' "$OUT" | grep -c '^PASS')
FAILURES=$(printf '%s\n' "$OUT" | grep -cE '^(FAIL|TIMEOUT|MEMKILL|CE)')

if printf '%s\n' "$OUT" | grep -q 'AddressSanitizer'; then
    printf '%s\n' "$OUT" | grep -A20 'AddressSanitizer' | head -30
    echo "heap-reset: ASAN report across $CYCLES cycles"
    exit 1
fi

if [ "$PASSES" -ne "$CYCLES" ] || [ "$FAILURES" -ne 0 ] || [ $STATUS -ne 0 ]; then
    printf '%s\n' "$OUT" | tail -20
    echo "heap-reset: $PASSES/$CYCLES passed, $FAILURES failed (exit $STATUS)"
    exit 1
fi

echo "heap-reset: $PASSES/$CYCLES reset cycles clean"
