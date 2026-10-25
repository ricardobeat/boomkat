#!/bin/sh
# Usage: run.sh <boomkat-binary>
# m_*.js print ns per iteration; they need head.js prepended.
# d_*.js are run under /usr/bin/time -l for retired instructions; subtract
# d_base.js and divide by N (20,000,000) for the per-operation count.
set -e
BK=${1:?boomkat binary}
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
for m in "$DIR"/m_*.js; do
  cat "$DIR/head.js" "$m" > "$TMP/$(basename "$m")"
  printf 'bk  '; "$BK" --script "$TMP/$(basename "$m")"
  printf 'ign '; node --jitless "$TMP/$(basename "$m")"
done
count() { { /usr/bin/time -l "$@" >/dev/null; } 2>&1 | awk '/instructions retired/{print $1}'; }
for d in "$DIR"/d_*.js; do
  printf '%s bk=%s ign=%s\n' "$(basename "$d")" "$(count "$BK" --script "$d")" "$(count node --jitless "$d")"
done
rm -rf "$TMP"
