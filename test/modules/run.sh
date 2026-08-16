#!/bin/bash
# Run all ESM module tests through the duktape_c3 engine.
# Each test is an entry main.js run with --module flag.
# Pass = exit 0; Fail = non-zero exit (thrown string or runtime error).
# Usage: bash test/modules/run.sh [engine_binary]
# Returns non-zero if any test fails.

ENGINE="${1:-./out/duktape_c3}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

# Each entry: "subdirectory:description"
TESTS=(
  "t01_named:named import+export (function)"
  "t02_const_value:const/value export"
  "t03_aliased:aliased import (as)"
  "t04_default_fn:default export — function form"
  "t05_default_value:default export — primitive value"
  "t06_namespace:namespace import (import * as)"
  "t07_reexport:re-export (export {} from)"
  "t08_chain:multi-level dependency chain (A->B->C)"
  "t09_multi_named:multiple named exports/imports"
  "t10_smoke:smoke — module with no imports/exports"
  "t11_colord:colord — ESM color manipulation library"
  "t12_tinycolor:tinycolor — ESM color manipulation library"
  "t13_unresolvable:unresolvable import is a link-time SyntaxError"
  "t14_resolve_accept:resolvable import forms must not be over-rejected"
  "t15_hoist_asi:function decl after ASI'd statement must be hoisted/exported"
)

for entry in "${TESTS[@]}"; do
  subdir="${entry%%:*}"
  desc="${entry#*:}"
  mainfile="$DIR/$subdir/main.js"
  name="modules/$subdir"

  start=$(python3 -c "import time; print(time.time())")
  output=$(timeout 5 "$ENGINE" --module "$mainfile" 2>&1)
  rc=$?
  end=$(python3 -c "import time; print(time.time())")
  ms=$(python3 -c "print(int(($end - $start) * 1000))")

  if [ "$rc" -eq 0 ]; then
    echo "  ok ($ms ms): $name — $desc"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    if [ "$rc" -eq 138 ] || [ "$rc" -eq 134 ] || [ "$rc" -eq 139 ]; then
      echo "FAIL ($ms ms): $name — $desc [crash/signal rc=$rc]"
    elif echo "$output" | grep -qi "compile\|SyntaxError\|parse error"; then
      echo "  CE ($ms ms): $name — $desc [compile error]"
    else
      echo "FAIL ($ms ms): $name — $desc"
    fi
    echo "$output" | head -4 | sed 's/^/      | /'
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
