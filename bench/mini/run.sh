#!/bin/sh
# Times the mini benches: run.sh [binary] [bench ...]
# Prints ms per benchmark; QK=1 adds a QuickJS column for comparison.
cd "$(dirname "$0")"
bk=${1:-../../out/boomkat}; shift 2>/dev/null
benches=${*:-$(ls *.js)}
for f in $benches; do
  f=${f%.js}.js
  "$bk" --script "$f" 2>&1 | while read -r line; do
    if [ -n "$QK" ]; then printf '%-40s' "$line"; else echo "$line"; fi
  done
  [ -n "$QK" ] && echo " | qjs $(${QJS:-qjs} "$f" 2>&1 | tr '\n' ' ')"
done
