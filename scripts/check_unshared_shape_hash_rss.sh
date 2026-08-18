#!/bin/bash
# Regression guard: adding properties to one object must cost memory linear in
# the property count, not quadratic.
#
# The property hash table lives on the Shape. Every put_prop moves the object
# to a new shape, so an object whose shapes no other object reaches would
# build a fresh table per property, each one covering the whole chain from the
# root. That is O(N^2) memory for a single object: 4,000 properties took 280
# MB, and test/engine/shape_id_exhaustion.js (80,000 distinct shapes, header
# comment "Runtime is roughly 100ms") grew to about 6 GB and was killed by the
# OOM killer before printing anything.
#
# The fix builds a table only for a shape a second object actually reaches,
# since only sharing amortizes the cost. Correctness is identical either way,
# which is why test/test_shape_hash_unshared.js passes with and without it and
# cannot be the guard. Peak RSS is the only signal that separates them, so the
# check lives here rather than in test/.
#
# Doubling the property count doubles the work in the linear case and
# quadruples it in the quadratic one, so the ratio between the two sizes is
# what matters, not an absolute byte budget (which would be machine- and
# allocator-dependent).
#
# Usage: ./scripts/check_unshared_shape_hash_rss.sh [path/to/runner]

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${1:-$PROJ_DIR/out/boomkat}"

if [ ! -x "$RUNNER" ]; then
    echo "FAIL: runner not found or not executable: $RUNNER" >&2
    exit 1
fi

# Measured at these sizes: 4.4 MB then 4.9 MB fixed (112%), 73 MB then 280 MB
# quadratic (383%). A ceiling of 200% sits far outside the noise in both
# directions, and still catches a growth rate meaningfully above linear.
MAX_RATIO_PCT=200
SMALL=2000
LARGE=4000

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

write_script() {
    local n="$1"
    cat > "$TMPDIR_RUN/props_$n.js" <<EOF
// Keys unique to this object, so no other object ever takes these
// transitions and every shape in the chain has exactly one user.
var o = {};
for (var i = 0; i < $n; i++) { o["uniq_" + i] = i; }
var bad = 0;
for (var i = 0; i < $n; i++) { if (o["uniq_" + i] !== i) { bad++; } }
if (bad !== 0) { print("FAIL: " + bad + " wrong reads"); }
EOF
}

write_script "$SMALL"
write_script "$LARGE"

measure_rss_kb() {
    local script="$1"
    local output
    output=$(/usr/bin/time -l "$RUNNER" "$script" 2>&1 >/dev/null) || true
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)
    if [ -z "$rss_bytes" ]; then echo ""; return; fi
    echo $(( rss_bytes / 1024 ))
}

# A wrong answer here matters more than the memory, so fail on it first.
for n in "$SMALL" "$LARGE"; do
    if "$RUNNER" "$TMPDIR_RUN/props_$n.js" | grep -q FAIL; then
        echo "SOME TESTS FAILED"
        echo "FAIL: property reads returned wrong values at $n properties." >&2
        exit 1
    fi
done

small_kb=$(measure_rss_kb "$TMPDIR_RUN/props_$SMALL.js")
large_kb=$(measure_rss_kb "$TMPDIR_RUN/props_$LARGE.js")

if [ -z "$small_kb" ] || [ -z "$large_kb" ] || [ "$small_kb" = "0" ]; then
    echo "FAIL: could not measure peak RSS (needs /usr/bin/time -l)" >&2
    exit 1
fi

ratio_pct=$(( large_kb * 100 / small_kb ))

echo "${SMALL} unshared props : ${small_kb} KB"
echo "${LARGE} unshared props : ${large_kb} KB"
echo "ratio                 : ${ratio_pct}% (ceiling ${MAX_RATIO_PCT}%)"

if [ "$ratio_pct" -gt "$MAX_RATIO_PCT" ]; then
    echo "SOME TESTS FAILED"
    echo "FAIL: doubling the property count cost ${ratio_pct}% of the peak RSS." >&2
    echo "      Hash tables are being built per shape on an unshared chain." >&2
    exit 1
fi

echo "unshared_shape_hash_rss: 1 passed, 0 failed"
