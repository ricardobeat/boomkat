#!/bin/bash
# Regression guard: compiling the local test corpus must be clean under
# AddressSanitizer.
#
# The compiler's own buffers are sized from counters that are easy to get
# wrong, and a bad bound there is silent: the overwritten bytes usually belong
# to another live allocation, so the wrong answer surfaces somewhere else
# entirely, or not at all. Sizing the move-elimination liveness bitsets to the
# register high-water mark did exactly that. moveelim_a_is_read reports field
# A as a register for opcodes where it is really a packed branch offset (JUMP,
# JMP_LT, JMP_SNEQ), and those values run past max_reg, so every compile wrote
# past the end of the liveness arena. `var x = 1;` was enough to trigger it.
# Every functional gate stayed green.
#
# This runs the ASan build over the corpus for the compile alone, which is
# where that class of bug lives and is much cheaper than executing everything.
# The runner reports test failures on stdout; what matters here is whether ASan
# printed a report on stderr, so the exit status of the engine is ignored.
#
# Usage: ./scripts/check_compile_asan.sh [path/to/test262_runner_asan]

set -uo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${1:-$PROJ_DIR/out/test262_runner_asan}"

if [ ! -x "$RUNNER" ]; then
    echo "FAIL: ASan runner not found or not executable: $RUNNER" >&2
    echo "      Build it with: just build-asan" >&2
    exit 1
fi

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# The flat test/*.js sweep, plus the engine tests. Both are hand-written and
# between them cover the syntax the compiler has to handle.
#
# Two files are excluded because ASan changes their behavior rather than the
# engine's memory handling. test_async_500k.js is a 500,000-iteration perf
# stress test that times out under the sanitizer's slowdown; the local suite
# skips it for the same reason. native_reentry_stack_guard.js drives recursion
# through native builtins until it hits the engine's run-depth guard, and ASan
# inflates each frame enough that the C stack overflows first, so it segfaults
# here while passing on the normal build.
ALL=$(ls "$PROJ_DIR"/test/*.js "$PROJ_DIR"/test/engine/*.js 2>/dev/null)
SKIP="test_async_500k.js native_reentry_stack_guard.js"
FILES=""
for f in $ALL; do
    case " $SKIP " in *" $(basename "$f") "*) continue;; esac
    FILES="$FILES $f"
done

if [ -z "$FILES" ]; then
    echo "FAIL: found no test files to compile" >&2
    exit 1
fi

total=0
crashed=0
failed_files=""

for f in $FILES; do
    total=$(( total + 1 ))
    # halt_on_error=0 keeps the sweep going so one bad file does not hide the
    # rest; each report still lands in the log.
    printf '%s\n' "$f" | \
        ASAN_OPTIONS="halt_on_error=0:detect_leaks=0" \
        timeout 120 "$RUNNER" --worker \
        > "$TMPDIR_RUN/out.log" 2> "$TMPDIR_RUN/err.log"
    rc=$?
    # A signal death (139 segv, 133/134 trap or abort) is a finding even when
    # ASan printed nothing: the process died before it could report. 124 is the
    # timeout, which is a hang rather than a memory error but still a failure.
    if [ "$rc" -ge 124 ] \
       || grep -q "AddressSanitizer" "$TMPDIR_RUN/err.log" "$TMPDIR_RUN/out.log" 2>/dev/null; then
        crashed=$(( crashed + 1 ))
        failed_files="$failed_files $f(rc=$rc)"
        if [ "$crashed" -le 3 ]; then
            echo "--- compiling $(basename "$f") exited rc=$rc ---"
            grep -A6 "AddressSanitizer" "$TMPDIR_RUN/err.log" "$TMPDIR_RUN/out.log" 2>/dev/null | head -12
        fi
    fi
done

echo "compiled ${total} files under ASan, ${crashed} produced a report"

if [ "$crashed" -gt 0 ]; then
    echo "SOME TESTS FAILED"
    echo "FAIL: AddressSanitizer reported memory errors while compiling:" >&2
    for f in $failed_files; do echo "      $(basename "$f")" >&2; done
    exit 1
fi

echo "compile_asan: ${total} passed, 0 failed"
