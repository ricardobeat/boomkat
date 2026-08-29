#!/bin/bash
# console value rendering for the SLIM build's tiny formatter.
#
# Separate from run.sh because the two formatters are held to different bars.
# run.sh diffs against output captured verbatim from Node, so a pass means this
# engine agrees with the de-facto behaviour byte for byte. The tiny formatter
# deliberately renders LESS — no column layout, no per-class form for Map, Set,
# Date or RegExp — so that bar does not apply and tiny.expected.txt records this
# formatter's own contract instead.
#
# Two lines in the fixture are not about looks, and a regression in either is a
# behaviour change rather than a formatting one:
#
#   "getter invocations: 0"   rendering must not run user code
#   the line after the cycle  rendering must terminate on a self-reference
#
# Requires a SLIM build; against a default build the full formatter answers and
# the diff will fail loudly, which is the intended signal rather than a skip.
#
# Usage: bash test/console_format/run_tiny.sh [engine_binary]

ENGINE="${1:-./out/boomkat}"
DIR="$(cd "$(dirname "$0")" && pwd)"

got="$(timeout 30 "$ENGINE" "$DIR/tiny.js" 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "FAIL: console_format tiny — engine exited $rc"
  printf '%s\n' "$got" | head -5 | sed 's/^/      | /'
  echo "Console format (tiny): 0 passed, 1 failed"
  exit 1
fi

# The cyclic and long-array cases sit near the end, so reaching the final line
# is what proves neither ran away.
if [ "$(printf '%s\n' "$got" | tail -1)" != "done" ]; then
  echo "FAIL: console_format tiny — output did not reach the final line"
  echo "Console format (tiny): 0 passed, 1 failed"
  exit 1
fi

if ! diff -u "$DIR/tiny.expected.txt" <(printf '%s\n' "$got") > /tmp/cf_tiny_diff.$$ 2>&1; then
  echo "FAIL: console_format tiny — output differs from the recorded contract"
  head -30 /tmp/cf_tiny_diff.$$ | sed 's/^/      | /'
  rm -f /tmp/cf_tiny_diff.$$
  echo "Console format (tiny): 0 passed, 1 failed"
  exit 1
fi
rm -f /tmp/cf_tiny_diff.$$

echo "Console format (tiny): $(wc -l < "$DIR/tiny.expected.txt" | tr -d ' ') lines matched contract"
exit 0
