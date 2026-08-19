#!/bin/bash
# Assert that building many DISTINCT short-lived strings scales linearly.
#
# Distinct from check_string_concat_scaling.sh, which builds one long string by
# repeated `+=`. Here every iteration produces a separate small string, so the
# cost is not copying an accumulator but the string TABLE those strings are
# interned into.
#
# sweep_strings scans that table in full on every GC cycle, while the collection
# budget counted only objects marked. Building 400k strings grew the table to
# 524,288 slots and swept it 197 times: 41 million slot visits against 605k
# objects marked, so collections were scheduled as if the table cost nothing.
# Measured at 50k against 400k (8x the work): about 5.5x the time with the fix,
# about 15x without it. Linear would be 8x, quadratic 64x, so the threshold of
# 9x sits just above linear-plus-noise and far below the broken curve.
#
# Each size runs in a FRESH PROCESS, which is what makes this check work. Within
# one process the first loop already grows the table, so a later loop never sees
# a cold one and the curve looks linear even on a broken engine — an in-process
# version of this test passed against the unfixed build.
#
# Like its sibling this is a scaling assertion rather than a speed one: it
# compares the engine against itself at two sizes, so a constant-factor
# slowdown passes and only a change in the growth curve fails.
#
# Usage: bash scripts/check_string_table_scaling.sh [engine_binary]

set -u
ENGINE="${1:-./out/boomkat}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SMALL=50000
LARGE=400000         # 8x the work
THRESHOLD=9          # 8x work: measured ~5.5x fixed, ~15x unfixed

# The loop uses `let`/`const` deliberately. A per-iteration binding allocates an
# environment record each time round, and it is that allocation rate which
# drives the collection frequency that exposes the table sweep. The same loop
# written with `var` allocates nothing per iteration, collects far less often,
# and runs at 71ms against 127ms here — fast enough that the bug does not show.
gen() {
  printf 'let len = 0;\nfor (let i = 0; i < %s; i++) { const s = "item " + i + " of x"; len += s.length; }\nprint(len);\n' "$1"
}

# Median of three, in milliseconds. Each run is its own process, so every
# measurement starts from an empty string table.
time_ms() {
  local file="$1" runs=() 
  for _ in 1 2 3; do
    local start end
    start=$(python3 -c 'import time; print(int(time.time()*1000))')
    timeout 120 "$ENGINE" "$file" > /dev/null 2>&1 || { echo "ENGINE_FAILED"; return 1; }
    end=$(python3 -c 'import time; print(int(time.time()*1000))')
    runs+=($((end - start)))
  done
  printf '%s\n' "${runs[@]}" | sort -n | sed -n '2p'
}

gen "$SMALL" > "$TMP/small.js"
gen "$LARGE" > "$TMP/large.js"

t_small="$(time_ms "$TMP/small.js")" || { echo "FAIL: engine failed on the small case"; exit 1; }
t_large="$(time_ms "$TMP/large.js")" || { echo "FAIL: engine failed on the large case"; exit 1; }

# Guard against a clock too coarse to measure the small case.
if [ "$t_small" -lt 5 ]; then
  t_small=5
fi

ratio=$(python3 -c "print(round($t_large / $t_small, 2))")
verdict=$(python3 -c "print(1 if ($t_large / $t_small) > $THRESHOLD else 0)")

echo "string table scaling: ${SMALL} strings = ${t_small}ms, ${LARGE} strings = ${t_large}ms (8x work → ${ratio}x time)"

if [ "$verdict" -eq 1 ]; then
  echo "FAIL: 8x the work cost ${ratio}x the time (threshold ${THRESHOLD}x) — the string table sweep is not being accounted for in the GC budget"
  exit 1
fi

echo "PASS"
