#!/usr/bin/env bash
# Run every .js test in this directory through ../../out/duktape_c3 and print a
# per-file PASS/FAIL table plus a totals line.
#
# Convention:
#   - Positive tests: expect exit code 0 AND the last non-empty line of
#     stdout to be exactly "PASS".
#   - Negative-syntax tests (name ends in "-syntax-err.js"): expect a
#     nonzero exit code AND "SyntaxError" to appear somewhere in stderr.
#
# Usage: tests/private/run.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_JS="$SCRIPT_DIR/../../out/duktape_c3"

if [ ! -x "$RUN_JS" ]; then
    echo "error: $RUN_JS not found or not executable (build it with 'make duktape_c3')" >&2
    exit 1
fi

pass_count=0
fail_count=0

printf "%-55s %-6s %s\n" "TEST" "RESULT" "DETAIL"
printf "%-55s %-6s %s\n" "----" "------" "------"

for f in "$SCRIPT_DIR"/*.js; do
    name="$(basename "$f")"

    stdout_out="$("$RUN_JS" "$f" 2>/tmp/run_private_stderr.$$)"
    rc=$?
    stderr_out="$(cat /tmp/run_private_stderr.$$)"
    rm -f /tmp/run_private_stderr.$$

    if [[ "$name" == *-syntax-err.js ]]; then
        if [ $rc -ne 0 ] && echo "$stderr_out" | grep -q "SyntaxError"; then
            printf "%-55s %-6s %s\n" "$name" "PASS" ""
            pass_count=$((pass_count + 1))
        else
            printf "%-55s %-6s %s\n" "$name" "FAIL" "expected nonzero exit + SyntaxError in stderr (rc=$rc)"
            fail_count=$((fail_count + 1))
        fi
    else
        last_line="$(printf '%s\n' "$stdout_out" | grep -v '^[[:space:]]*$' | tail -n1)"
        if [ $rc -eq 0 ] && [ "$last_line" = "PASS" ]; then
            printf "%-55s %-6s %s\n" "$name" "PASS" ""
            pass_count=$((pass_count + 1))
        else
            detail="rc=$rc last_line=$(printf '%q' "$last_line")"
            printf "%-55s %-6s %s\n" "$name" "FAIL" "$detail"
            fail_count=$((fail_count + 1))
        fi
    fi
done

echo
total=$((pass_count + fail_count))
echo "totals: $pass_count/$total passed, $fail_count failed"

[ $fail_count -eq 0 ]
