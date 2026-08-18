#!/bin/bash
# Run the GC-lifetime tests under the GC_STRESS + ASAN build.
#
# GC_STRESS pins the collector's trigger so a mark-and-sweep runs at every
# allocation. Any value that lives only in a raw C3 local, a stale valstack
# slot, or a field the mark phase does not visit is then freed while still in
# use, and ASAN turns that into a use-after-poison abort at the exact read
# instead of an intermittent segfault somewhere later.
#
# The list is deliberately short: this build is orders of magnitude slower than
# the normal one, so it covers the tests that hold values across a suspension,
# a microtask boundary, or a native-to-VM re-entry, which is where missed roots
# actually live. Add a test here when it exercises a new lifetime boundary, not
# merely because it is new.
#
# Usage: bash scripts/run_gc_stress.sh [engine_binary]
# Returns non-zero if any test fails.

ENGINE="${1:-./out/boomkat_gc_stress}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TESTS=(
  test/test_async_loops.js
  test/async_gen_gc_lifetime.js
  test/env_chain_gc_lifetime.js
  test/proxy_ownkeys_gc_lifetime.js
)

# Generous per-test budget: a collection per allocation is slow enough that a
# normal-build second becomes minutes. Still bounded, so a genuine hang fails
# rather than hanging the gate.
TIMEOUT=900

PASS=0
FAIL=0

for t in "${TESTS[@]}"; do
  output=$(cd "$ROOT" && timeout "$TIMEOUT" "$ENGINE" "$t" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ] && ! echo "$output" | grep -q "FAIL"; then
    PASS=$((PASS + 1))
    echo "ok   $t"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $t (exit $rc)"
    echo "$output" | tail -20 | sed 's/^/      | /'
  fi
done

echo "gc-stress: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
