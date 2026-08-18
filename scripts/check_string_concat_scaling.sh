#!/bin/bash
# Assert that building a string with `+=` in a loop scales linearly.
#
# Each concatenation used to copy (and intern) the whole accumulator, making
# the loop O(n^2): doubling the iteration count roughly quadrupled the time.
# Measured before the fix — 10k: 23ms, 20k: 79ms, 40k: 295ms, 80k: 1165ms,
# converging on 4x per doubling, while QuickJS stayed flat at 4-7ms.
#
# This is a scaling assertion, not a speed one: it compares the engine against
# itself at two sizes, so it does not depend on the host being fast or on a
# reference binary being present. A constant-factor slowdown passes; only a
# change in the growth curve fails.
#
# The invariant: 4x the work must cost well under 4x the time. Linear would be
# ~4x, quadratic ~16x. The threshold is 8x — comfortably above linear-plus-noise
# and far below quadratic, so the check is not flaky on a loaded machine.
#
# Any fix must preserve the engine-wide interning invariant (string equality is
# pointer identity). The usual approach is to leave concatenation temporaries
# un-interned until they escape; src/hstring.c3 already contemplates exactly
# that case.
#
# Usage: bash scripts/check_string_concat_scaling.sh [engine_binary]

set -u
ENGINE="${1:-./out/boomkat}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SMALL=20000
LARGE=80000          # 4x the work
THRESHOLD=8          # fail if 4x the work costs more than 8x the time

gen() {
  printf 'var s = "";\nfor (var i = 0; i < %s; i++) { s += "abc"; }\nprint(s.length);\n' "$1"
}

# Median of three, in milliseconds.
time_ms() {
  local file="$1" best=() t
  for _ in 1 2 3; do
    local start end
    start=$(python3 -c 'import time; print(int(time.time()*1000))')
    timeout 120 "$ENGINE" "$file" > /dev/null 2>&1 || { echo "ENGINE_FAILED"; return 1; }
    end=$(python3 -c 'import time; print(int(time.time()*1000))')
    best+=($((end - start)))
  done
  printf '%s\n' "${best[@]}" | sort -n | sed -n '2p'
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

echo "string += scaling: ${SMALL} iters = ${t_small}ms, ${LARGE} iters = ${t_large}ms (4x work → ${ratio}x time)"

if [ "$verdict" -eq 1 ]; then
  echo "FAIL: 4x the work cost ${ratio}x the time (threshold ${THRESHOLD}x) — concatenation is super-linear"
  exit 1
fi

echo "PASS: string concatenation scales linearly"
