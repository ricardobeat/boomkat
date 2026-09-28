#!/bin/bash
# Run the GC-lifetime tests under the GC_STRESS + ASAN build.
#
# GC_STRESS requests a cycle after each allocation. Legal VM safepoints advance
# the cooperative collector; GC_VERIFY checks its result before reclamation.
# ASAN reports access to reclaimed storage, including missed native roots.
#
# The target also builds with POOL_BYPASS, which is what makes the ASAN half of
# that sentence true. Objects normally come from a FixedBlockPool whose frees
# return blocks to a freelist and never reach free(), so ASAN has nothing to
# poison and a use-after-free reads memory that is still mapped -- silently
# seeing whichever object the pool has since handed out at that address. With
# the bypass every object is a real alloc/free pair and the offending read is
# reported where it happens.
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
  test/test_async_gen_drain_reentry.js
  test/env_chain_gc_lifetime.js
  test/proxy_ownkeys_gc_lifetime.js
  test/proxy_spread_gc_lifetime.js
  test/native_construct_gc_lifetime.js
  test/class_fields_gc_lifetime.js
  test/callback_gc_lifetime.js
  test/native_frame_storage.js
  test/generator_register_ownership.js
  test/array_storage_layout.js
  test/temproot_gc_lifetime.js
  test/callee_gc_lifetime.js
  test/test_symbol_long_description.js
  test/string_callback_ownership.js
  test/gc_incremental_roots.js
  test/gc_string_nonwritable.js
  test/destructuring_literal_defaults.js
  test/fixed_shape_literals.js
)

# Generous per-test budget: a collection per allocation is slow enough that a
# normal-build second becomes minutes. Still bounded, so a genuine hang fails
# rather than hanging the gate.
TIMEOUT=900

PASS=0
FAIL=0

for t in "${TESTS[@]}"; do
  output=$(cd "$ROOT" && timeout "$TIMEOUT" "$ENGINE" --script "$t" 2>&1)
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
