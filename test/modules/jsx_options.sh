#!/bin/bash
# JSX command-line options: they override tsconfig.json/jsconfig.json, and a
# pragma comment in the file overrides them. Fixtures live in test/modules/jsx_cli,
# whose tsconfig.json selects the classic runtime with factory `h`.
#
# Usage: bash test/modules/jsx_options.sh [engine_binary]

ENGINE="${1:-./out/boomkat}"
DIR="$(cd "$(dirname "$0")" && pwd)/jsx_cli"
PASS=0
FAIL=0

# check <description> <expected stdout> <engine args...>
check() {
  local desc="$1" want="$2"; shift 2
  local got
  got=$("$ENGINE" "$@" 2>&1)
  if [ "$got" = "$want" ]; then
    echo "  ok: $desc"; PASS=$((PASS + 1))
  else
    echo "FAIL: $desc: got '$got', want '$want'"; FAIL=$((FAIL + 1))
  fi
}

check "tsconfig factory applies"                 "config:a" "$DIR/view.jsx"
check "--jsx-factory overrides tsconfig"          "flag:a"   --jsx-factory=g "$DIR/view.jsx"
check "--jsx-import-source selects automatic"     "auto:a"   --jsx-import-source="$DIR/rt" "$DIR/auto.jsx"
check "--jsx-runtime=automatic with a source"     "auto:a"   --jsx-runtime=automatic --jsx-import-source="$DIR/rt" "$DIR/auto.jsx"
check "a pragma overrides the flags"              "pragma:a" --jsx-import-source="$DIR/rt" "$DIR/pragma.jsx"
check "--jsx parses stdin"                        "x:a"      --jsx --jsx-factory=h - <<< "const h = (t) => 'x:' + t; console.log(<a />);"
check "--jsx-runtime rejects an unknown value"    "boomkat: --jsx-runtime expects automatic or classic" --jsx-runtime=bogus "$DIR/view.jsx"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
