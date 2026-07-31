#!/bin/bash
# Run all engine conformance tests through a given JS engine.
# Usage: bash test/engine/run.sh <engine_binary>
# Returns non-zero if any test fails.

set -e
ENGINE="${1:?Usage: $0 <engine_binary>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SLOW=0

for f in "$DIR"/*.js; do
    name=$(basename "$f")
    start=$(python3 -c "import time; print(time.time())")
    output=$(timeout 2 "$ENGINE" "$f" 2>&1) && rc=0 || rc=$?
    end=$(python3 -c "import time; print(time.time())")
    ms=$(python3 -c "print(int(($end - $start) * 1000))")
    if [ $rc -ne 0 ]; then
        echo "FAIL ($ms ms) [$ENGINE]: $name"
        echo "$output" | head -5
        FAIL=$((FAIL + 1))
    elif [ "$ms" -gt 500 ]; then
        echo "SLOW ($ms ms) [$ENGINE]: $name"
        SLOW=$((SLOW + 1))
        PASS=$((PASS + 1))
    else
        echo "  ok ($ms ms) [$ENGINE]: $name"
        PASS=$((PASS + 1))
    fi
done

echo ""
echo "Results [$ENGINE]: $PASS passed, $FAIL failed, $SLOW slow (>500ms)"
[ "$FAIL" -eq 0 ]
