#!/usr/bin/env bash
# Force every optimizing-tier exit reason (--opt-force-exit) in each function the
# regression scripts compile and compare the output of the resumed baseline code
# with the interpreter's. Also takes the discard path (--opt-exit-max=2), which
# reoptimizes a function twice more before it stays baseline. Run through
# scripts/guard.sh.
set -u
BIN=${BIN:-./out/boomkat}
FILES=${FILES:-"test/jit_baseline_arith.js test/jit_baseline_calls.js test/jit_baseline_props.js test/jit_baseline_misc.js test/jit/feedback_arith.js test/jit/opt_overflow.js test/jit/opt_elements.js test/jit/opt_equality.js test/jit/opt_fields.js test/jit/call_global.js test/jit/return_tracked.js test/jit/new_obj.js test/jit/put_absent.js test/jit/put_missed.js test/jit/alloc.js test/jit/ops_typeof_instanceof_add.js test/jit/props_relay.js test/jit/vars.js"}
REASONS="overflow not-int32 not-number shape bounds hole callee inline-slowcall alloc-slow throw-path forced"
fails=0
for f in $FILES; do
    ref=$($BIN --memory-limit=512 --script "$f" 2>&1)
    for r in $REASONS; do
        for spec in "$r" "$r:3:2" "$r:9:1"; do
            out=$($BIN --memory-limit=512 --opt-force-exit="$spec" --script "$f" 2>&1)
            if [ "$out" != "$ref" ]; then echo "DIFF $f --opt-force-exit=$spec"; fails=$((fails+1)); fi
        done
    done
    out=$($BIN --memory-limit=512 --opt-force-exit=forced:2:5 --opt-exit-max=2 --script "$f" 2>&1)
    if [ "$out" != "$ref" ]; then echo "DIFF $f discard path"; fails=$((fails+1)); fi
done
# Each reason must be counted, and the discard path must reoptimize and refuse.
for r in $REASONS; do
    n=$($BIN --memory-limit=512 --opt-force-exit="$r" --jit-stats --script test/jit_baseline_calls.js 2>&1 | grep -c "^opt exit $r: ")
    if [ "$n" != 1 ]; then echo "NOCOUNT $r"; fails=$((fails+1)); fi
done
st=$($BIN --memory-limit=512 --opt-force-exit=forced:2:5 --opt-exit-max=2 --jit-stats --script test/jit_baseline_calls.js 2>&1 | grep "^opt: ")
case "$st" in *"discarded 0"*|*"(0 reoptimized)"*|"") echo "NODISCARD: $st"; fails=$((fails+1));; esac
echo "opt-exits fails=$fails"
[ "$fails" = 0 ]
