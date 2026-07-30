#!/bin/bash
# Run the local JS test suite.
#
# Three surfaces, because they need different invocations:
#   1. test/*.js       — plain scripts, run as `duktape_c3 <file>`.
#   2. test/modules/   — ESM fixtures, run as `duktape_c3 --module <entry>`;
#                        delegated to test/modules/run.sh, which owns the
#                        entry-point list. The flat sweep skips the directory.
#   3. test/uncaught/  — uncaught-exception reporting on stderr; delegated to
#                        test/uncaught/run.sh. These exit non-zero on purpose,
#                        so the flat sweep cannot express them.
#
# A test fails if the engine exits non-zero or prints a line containing FAIL
# (the convention local tests use for an assertion-failure branch).
#
# Usage: bash test/run_local.sh [engine_binary]
# Returns non-zero if any test fails.

ENGINE="${1:-./out/duktape_c3}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

# Passes, but runs ~20s — a perf stress test, not a regression check.
# Run it directly (`just run test/test_async_500k.js`) when touching async.
SKIP="test_async_500k.js"

for f in "$DIR"/*.js; do
  name="$(basename "$f")"
  case " $SKIP " in *" $name "*) continue;; esac

  output=$(timeout 30 "$ENGINE" "$f" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ] && ! echo "$output" | grep -q "FAIL"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name"
    echo "$output" | head -4 | sed 's/^/      | /'
  fi
done

echo ""
echo "Scripts: $PASS passed, $FAIL failed (skipped: $SKIP)"

# ESM fixtures — run.sh reports its own tally and exit status.
echo ""
bash "$DIR/modules/run.sh" "$ENGINE"
MOD_RC=$?

# Uncaught-exception reporting — asserted from the shell because these cases
# exit non-zero with diagnostics on stderr by construction, which the flat
# sweep above would count as failures.
echo ""
bash "$DIR/uncaught/run.sh" "$ENGINE"
UNC_RC=$?

[ "$FAIL" -eq 0 ] && [ "$MOD_RC" -eq 0 ] && [ "$UNC_RC" -eq 0 ]
