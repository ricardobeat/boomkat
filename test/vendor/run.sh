#!/bin/bash
# Run all vendor library ESM tests through a given JS engine.
# Each test file imports its vendor library via ESM `import`.
# Classifies: ok, CE (compile error), VE (VM error), TF (test fail), timeout.
# Usage: bash test/vendor/run.sh <engine_binary>
# Returns non-zero if any test fails.

set -e
ENGINE="${1:?Usage: $0 <engine_binary>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

TESTS="marked hex_rgb rgb_hex parse_ms"

for testname in $TESTS; do
    testfile="$DIR/test_${testname}.js"
    name="vendor/${testname}"

    start=$(python3 -c "import time; print(time.time())")
    output=$(timeout 5 "$ENGINE" -m "$testfile" 2>&1) && rc=0 || rc=$?
    end=$(python3 -c "import time; print(time.time())")
    ms=$(python3 -c "print(int(($end - $start) * 1000))")

    if [ "$rc" -eq 0 ]; then
        echo "  ok ($ms ms): $name"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        if echo "$output" | grep -q "Compile failed"; then
            echo "    CE ($ms ms): $name — compile error"
        elif echo "$output" | grep -q "VM error"; then
            echo "    VE ($ms ms): $name — VM error"
            echo "$output" | head -2 | sed 's/^/      | /'
        elif echo "$output" | grep -q "FAIL:"; then
            echo "    TF ($ms ms): $name — test assertions failed"
            echo "$output" | grep "FAIL:" | head -3 | sed 's/^/      | /'
        else
            echo "  FAIL ($ms ms): $name — exit=$rc"
            echo "$output" | head -3 | sed 's/^/      | /'
        fi
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
