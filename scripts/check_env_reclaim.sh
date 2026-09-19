#!/usr/bin/env bash
# Verify environment records are reclaimed after their scopes exit (plans/085).
# The counter harness runs a 100k-capture loop and forces a quiescent collection,
# then reports live cells and reserved bytes. Reclamation must leave a bounded
# live set (a handful of permanent global records), not the 100k cells allocated.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$(./out/env_pool_stats test/env_retention_baseline.js)" || {
    echo "env-reclaim: harness failed"
    exit 1
}
echo "$OUT"

# live_cells is the third field of the harness's single output line.
LIVE="$(echo "$OUT" | sed -E 's/.*env_live_cells=([0-9]+).*/\1/')"
ALLOC="$(echo "$OUT" | sed -E 's/.*env_alloc_count=([0-9]+).*/\1/')"

if [ -z "$LIVE" ] || [ -z "$ALLOC" ]; then
    echo "env-reclaim: could not parse counters"
    exit 1
fi

# 100k captures must not leave more than a handful of live records.
if [ "$LIVE" -gt 16 ]; then
    echo "env-reclaim: FAIL: $LIVE live cells after $ALLOC captures"
    exit 1
fi

echo "env-reclaim: $LIVE live cells after $ALLOC captures (reclaimed $((ALLOC - LIVE)))"
