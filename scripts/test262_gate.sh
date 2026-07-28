#!/usr/bin/env bash
#
# test262_gate.sh — Two-consecutive-run zero-fail gate for test262.
#
# Runs the full test262 suite twice in sequence and requires both runs to
# report zero failures across every phase (0 fail, 0 unexpected/expected-
# runtime CE). A single green run can hide a flaky/timing-sensitive test
# (e.g. a test that only times out under load); running twice back to back
# catches that class of flake without weakening the pass criterion itself.
#
# Usage:
#   ./scripts/test262_gate.sh
#
# Exits non-zero and names the failing run + fail count if either run is
# not clean. Prints total wall time either way.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

START=$(date +%s)

run_and_check() {
    local n="$1"
    local log
    log=$(mktemp)
    echo "=== test262-gate: run $n/2 ===" >&2
    python3 "$SCRIPT_DIR/run_test262.py" 2>&1 | tee "$log" >&2

    # "Overall (raw): N pass / M fail / K CE (P%)" — printed once at the end
    # of a full (all-phase) run. Its fail count already folds in every
    # non-pass verdict (FAIL, TIMEOUT, MEMKILL, unexpected/expected-runtime
    # CE) via _summarize_results, so this one number is a true zero-fail
    # check, not just an absence of the word "fail".
    local line
    line=$(grep -m1 '^Overall (raw):' "$log")
    if [ -z "$line" ]; then
        echo "test262-gate: run $n produced no 'Overall (raw):' summary line — treating as failed" >&2
        rm -f "$log"
        return 1
    fi

    local fails
    fails=$(echo "$line" | sed -E 's/^Overall \(raw\):[[:space:]]*[0-9]+ pass \/ ([0-9]+) fail.*/\1/')
    rm -f "$log"

    if [ "$fails" -ne 0 ]; then
        echo "test262-gate: run $n FAILED with $fails failure(s)" >&2
        return 1
    fi
    echo "test262-gate: run $n clean (0 fail)" >&2
    return 0
}

cd "$PROJECT_DIR"

FAILED_RUN=0
run_and_check 1 || FAILED_RUN=1
if [ "$FAILED_RUN" -eq 0 ]; then
    run_and_check 2 || FAILED_RUN=2
fi

END=$(date +%s)
ELAPSED=$((END - START))
printf 'test262-gate: total wall time %dm%02ds\n' "$((ELAPSED / 60))" "$((ELAPSED % 60))"

if [ "$FAILED_RUN" -ne 0 ]; then
    echo "test262-gate: GATE FAILED (run $FAILED_RUN was not zero-fail)" >&2
    exit 1
fi

echo "test262-gate: GATE PASSED (2/2 runs zero-fail)"
