#!/bin/sh
# Instructions per call for bench/micro/regexp_*.js (N=2000000), minus the empty loop.
# Usage: scripts/regexp_micros.sh [binary] [args...]   (jsc: pass the jsc path, no args)
BIN=${1:-./out/boomkat}; shift 2>/dev/null
[ $# -eq 0 ] && case "$BIN" in *jsc) ;; *) set -- --jit --opt --script ;; esac
ins() { /usr/bin/time -l "$BIN" "$@" 2>&1 | awk '/instructions retired/{print $1}'; }
base=$(ins "$@" bench/micro/regexp_empty.js)
for f in exec_fail exec2 test replace_g replace_1 replace_none split match_g search; do
  v=$(ins "$@" bench/micro/regexp_$f.js)
  echo "$f $(( (v - base) / 2000000 ))"
done
