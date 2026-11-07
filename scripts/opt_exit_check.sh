#!/usr/bin/env bash
# Force every optimizing-tier exit reason (--opt-force-exit) in each function the
# regression scripts compile and compare the output of the resumed baseline code
# with the interpreter's. Also takes the discard path (--opt-exit-max=2), which
# reoptimizes a function twice more before it stays baseline. Run through
# scripts/guard.sh.
set -u
BIN=${BIN:-./out/boomkat}
FILES=${FILES:-"test/jit_baseline_arith.js test/jit_baseline_calls.js test/jit_baseline_props.js test/jit_baseline_misc.js test/jit/feedback_arith.js test/jit/opt_overflow.js test/jit/opt_elements.js test/jit/opt_equality.js test/jit/opt_fields.js test/jit/opt_store_field.js test/jit/opt_guard_elim.js test/jit/call_global.js test/jit/return_tracked.js test/jit/new_obj.js test/jit/put_absent.js test/jit/typed_length.js test/jit/put_missed.js test/jit/alloc.js test/jit/ops_typeof_instanceof_add.js test/jit/props_relay.js test/jit/vars.js test/jit/elements.js test/jit/opt_inline.js test/jit/opt_poly_field.js test/jit/opt_inline_view.js test/jit/opt_inline_branch.js test/jit/opt_inline_wide.js test/jit/opt_inline_wide_global.js test/jit/opt_objects.js test/jit/opt_inline_objload.js test/jit/opt_inline_cap.js test/jit/opt_inline_ops.js test/jit/opt_inline_ops2.js test/jit/opt_inline_nested.js test/jit/opt_inline_putelem.js test/jit/opt_inline_new.js test/jit/opt_inline_proto.js test/jit/opt_inline_ldreg.js test/jit/call_feedback.js test/jit/opt_inline_forward.js test/jit/opt_inline_getvar.js test/jit/opt_inline_dotcall.js test/jit/opt_inline_flatnested.js test/jit/opt_inline_fwd_site.js test/jit/opt_site_ban.js test/jit/opt_sink.js test/jit/opt_inline_exit_ban.js test/jit/opt_int_double_index.js test/jit/opt_int_asmjs.js test/jit/opt_int_typed.js test/jit/opt_poly_length.js test/jit/opt_inline_objwindow.js"}
REASONS="overflow not-int32 not-number shape bounds hole callee inline-slowcall alloc-slow throw-path forced"
fails=0
# Each file is independent: check them in parallel (JOBS, default the core count).
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
export BIN REASONS
check_task() {   # file reason ("discard" for the discard path)
    f=$1; r=$2
    ref=$($BIN --memory-limit=512 --script "$f" 2>&1)
    if [ "$r" = discard ]; then
        out=$($BIN --memory-limit=512 --opt-force-exit=forced:2:5 --opt-exit-max=2 --script "$f" 2>&1)
        if [ "$out" != "$ref" ]; then echo "DIFF $f discard path"; fi
        return
    fi
    specs="$r $r:3:2 $r:9:1 inline/$r inline/$r:0:2"
    # Bodies nested in inlined bodies: exits from the second and third level too.
    case "$f" in *nested*|*inline_new*|*opt_sink*|*inline_forward*|*inline_dotcall*|*fwd_site*) specs="$specs inline2/$r inline2/$r:3:2 inline3/$r inline3/$r:3:2";; esac
    for spec in $specs; do
        out=$($BIN --memory-limit=512 --opt-force-exit="$spec" --script "$f" 2>&1)
        if [ "$out" != "$ref" ]; then echo "DIFF $f --opt-force-exit=$spec"; fi
    done
}
export -f check_task
diffs=$(for f in $FILES; do for r in $REASONS discard; do echo "$f $r"; done; done | xargs -P "$JOBS" -L1 bash -c 'check_task $0 $1')
if [ -n "$diffs" ]; then echo "$diffs"; fails=$(echo "$diffs" | wc -l | tr -d ' '); fi
# An exit from an inlined body publishes the callee's frame; it must happen and be counted.
n=$($BIN --memory-limit=512 --opt-force-exit=inline/shape --jit-stats --script test/jit/opt_inline.js 2>&1 | grep -c "^opt inline: [1-9][0-9]* callees inlined, [1-9][0-9]* exits")
if [ "$n" != 1 ]; then echo "NOINLINEEXIT"; fails=$((fails+1)); fi
# Each reason must be counted, and the discard path must reoptimize and refuse.
for r in $REASONS; do
    n=$($BIN --memory-limit=512 --opt-force-exit="$r" --jit-stats --script test/jit_baseline_calls.js 2>&1 | grep -c "^opt exit $r: ")
    if [ "$n" != 1 ]; then echo "NOCOUNT $r"; fails=$((fails+1)); fi
done
st=$($BIN --memory-limit=512 --opt-force-exit=forced:2:5 --opt-exit-max=2 --jit-stats --script test/jit_baseline_calls.js 2>&1 | grep "^opt: ")
case "$st" in *"discarded 0"*|*"(0 reoptimized)"*|"") echo "NODISCARD: $st"; fails=$((fails+1));; esac
# A site that exits repeatedly is lowered generically by the rebuild instead of exiting again.
n=$($BIN --memory-limit=512 --jit --opt --jit-stats --script test/jit/opt_site_ban.js 2>&1 | grep -c "^opt: [1-9][0-9]* sites lowered generically")
if [ "$n" != 1 ]; then echo "NOBAN"; fails=$((fails+1)); fi
# An instruction of an inlined body that exits repeatedly keeps its call out of the next build: the
# exits stay few (the fixture takes 24 before the ban).
n=$($BIN --memory-limit=512 --jit --opt --jit-stats --script test/jit/opt_inline_exit_ban.js 2>&1 | sed -n 's/^opt inline: .* \([0-9]*\) exits from inlined bodies/\1/p')
if [ -z "$n" ] || [ "$n" -gt 8 ]; then echo "NOINLINEBAN $n"; fails=$((fails+1)); fi
# The 20 KB code cap evicts optimized bodies that were not entered since the last sweep.
n=$($BIN --memory-limit=512 --jit --opt --opt-always --opt-code-max=20000 --jit-stats --script test/jit/opt_inline_getvar.js 2>&1 | grep -c "^opt: [1-9][0-9]* evicted")
if [ "$n" != 1 ]; then echo "NOEVICT"; fails=$((fails+1)); fi
echo "opt-exits fails=$fails"
[ "$fails" = 0 ]
