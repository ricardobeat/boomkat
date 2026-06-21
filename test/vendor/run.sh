#!/bin/bash
# Run all vendor library tests through a given JS engine.
# Classifies failures as: compile-error, vm-error, test-fail, or timeout.
# Usage: bash test/vendor/run.sh <engine_binary>
# Returns non-zero if any test fails.

set -e
ENGINE="${1:?Usage: $0 <engine_binary>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

TESTS="he marked culori diff"

for lib in $TESTS; do
    vendor="$DIR/${lib}.js"
    testfile="$DIR/test_${lib}.js"
    name="vendor/${lib}"

    combined=$(mktemp /tmp/vendor_test_XXXX.js)
    cat "$vendor" "$testfile" > "$combined"

    start=$(python3 -c "import time; print(time.time())")
    output=$(timeout 5 "$ENGINE" "$combined" 2>&1) && rc=0 || rc=$?
    end=$(python3 -c "import time; print(time.time())")
    ms=$(python3 -c "print(int(($end - $start) * 1000))")
    rm -f "$combined"

    # Classify result
    if [ "$rc" -eq 0 ]; then
        echo "  ok ($ms ms) [$ENGINE]: $name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        if echo "$output" | grep -q "Compile failed"; then
            echo "    CE ($ms ms) [$ENGINE]: $name — compile error"
            echo "$output" | head -3 | sed 's/^/      | /'
        elif echo "$output" | grep -q "VM error"; then
            echo "    VE ($ms ms) [$ENGINE]: $name — VM error"
            first=$(echo "$output" | head -5)
            echo "      | $first"
        elif echo "$output" | grep -q "FAIL:"; then
            echo "  FAIL ($ms ms) [$ENGINE]: $name — assertions failed"
            echo "$output" | grep "FAIL:" | head -3 | sed 's/^/      | /'
        else
            echo "  FAIL ($ms ms) [$ENGINE]: $name — unknown error (rc=$rc)"
            echo "$output" | head -3 | sed 's/^/      | /'
        fi
    fi
done

echo ""
echo "Results [$ENGINE]: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
