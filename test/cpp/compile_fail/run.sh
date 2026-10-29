#!/bin/sh
# Each case must fail to compile with the diagnostic named on its first line:
#   // expect: <text>
CXX=${CXX:-c++}
dir=$(dirname "$0")
fail=0
n=0
for f in "$dir"/*.cpp; do
  n=$((n + 1))
  expect=$(sed -n '1s|^// expect: ||p' "$f")
  if out=$($CXX -std=c++17 -fno-exceptions -fno-rtti -Iinclude -I"$dir/../../../include" -Wall -Werror -fsyntax-only "$f" 2>&1); then
    echo "compile-fail: $f compiled"; fail=1
  elif ! printf '%s' "$out" | grep -qF -- "$expect"; then
    echo "compile-fail: $f lacks '$expect'"; printf '%s\n' "$out" | grep error | head -3; fail=1
  fi
done
[ $fail = 0 ] && echo "compile-fail: $n cases ok"
exit $fail
