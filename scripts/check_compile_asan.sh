#!/bin/bash
# Run the local and engine corpora under AddressSanitizer. Worker execution
# covers compilation, runtime and teardown; assertion failures are checked by
# the ordinary suites, while this gate checks crashes and sanitizer reports.
# Usage: ./scripts/check_compile_asan.sh [path/to/test262_runner_asan]

set -uo pipefail

# O0 sanitizer frames need more stack for the same bounded recursion tests.
# Keep the engine's recursion limits and exercise the native overflow guard.
stack_kb=$(ulimit -s)
hard_stack_kb=$(ulimit -Hs)
if [ "$stack_kb" != unlimited ] && [ "$stack_kb" -lt 65536 ]; then
    stack_target_kb=65536
    if [ "$hard_stack_kb" != unlimited ] && [ "$hard_stack_kb" -lt "$stack_target_kb" ]; then
        stack_target_kb=$hard_stack_kb
    fi
    ulimit -s "$stack_target_kb"
fi

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
# The async stress workload is outside the local regression suite.
ALL=$(ls "$PROJ_DIR"/test/*.js "$PROJ_DIR"/test/engine/*.js 2>/dev/null)
SKIP="test_async_500k.js"
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
            echo "--- running $(basename "$f") exited rc=$rc ---"
            grep -A6 "AddressSanitizer" "$TMPDIR_RUN/err.log" "$TMPDIR_RUN/out.log" 2>/dev/null | head -12
        fi
    fi
done

echo "ran ${total} files under ASan, ${crashed} produced a report"

if [ "$crashed" -gt 0 ]; then
    echo "SOME TESTS FAILED"
    echo "FAIL: AddressSanitizer reported memory errors or crashes:" >&2
    for f in $failed_files; do echo "      $(basename "$f")" >&2; done
    exit 1
fi

echo "compile_asan: ${total} passed, 0 failed"
