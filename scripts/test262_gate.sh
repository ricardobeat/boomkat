#!/usr/bin/env bash
#
# test262_gate.sh: zero-fail gate for test262.
#
# Runs the full test262 suite once and requires it to report zero failures
# across every suite (0 fail, 0 unexpected/expected-runtime CE). The suite is
# deterministic, with no flaky tests, so a single clean run is the gate.
#
# Usage:
#   ./scripts/test262_gate.sh
#
# Exits non-zero and names the fail count if the run is not clean. Prints total
# wall time either way.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

START=$(date +%s)

cd "$PROJECT_DIR"

log=$(mktemp)
python3 "$SCRIPT_DIR/run_test262.py" 2>&1 | tee "$log"

# "Overall (raw): N pass / M fail / K CE (P%)" is printed once at the end of a
# full (all-suite) run. Its fail count already folds in every non-pass verdict
# (FAIL, TIMEOUT, MEMKILL, unexpected/expected-runtime CE) via
# _summarize_results, so this one number is a true zero-fail check.
line=$(grep -m1 '^Overall (raw):' "$log")
if [ -z "$line" ]; then
    echo "test262-gate: no 'Overall (raw):' summary line, treating as failed" >&2
    rm -f "$log"
    exit 1
fi
fails=$(echo "$line" | sed -E 's/^Overall \(raw\):[[:space:]]*[0-9]+ pass \/ ([0-9]+) fail.*/\1/')
rm -f "$log"

END=$(date +%s)
ELAPSED=$((END - START))
printf 'test262-gate: total wall time %dm%02ds\n' "$((ELAPSED / 60))" "$((ELAPSED % 60))"

if [ "$fails" -ne 0 ]; then
    echo "test262-gate: GATE FAILED ($fails failure(s))" >&2
    exit 1
fi

echo "test262-gate: GATE PASSED (0 fail)"
