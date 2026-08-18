#!/bin/bash
# console output: format-specifier substitution (%s %d %i %f %o %O %j %c) and
# util.inspect-style value rendering.
#
# Its own surface because what is under test is what console WRITES to stdout,
# which a script in the flat test/*.js sweep cannot observe about itself. So the
# fixtures print and this driver diffs the whole stream.
#
# The target is the de-facto util.format and inspect behaviour shared across JS
# runtimes, not the bare WHATWG console Formatter — the two disagree on %j
# (WHATWG has none), on %o detail, and on %c (WHATWG applies CSS; the directive
# is ignored but its argument still consumed). The de-facto form is the useful
# target because real code is written against it.
#
# THE .expected.txt FILES ARE CAPTURED REFERENCE OUTPUT, not this engine's own,
# produced verbatim with:
#
#     node test/console_format/cases.js  > test/console_format/cases.expected.txt
#     node test/console_format/matrix.js > test/console_format/matrix.expected.txt
#
# so they can be re-derived and audited at any time, and a passing run means
# this engine agrees with the reference byte for byte rather than merely
# agreeing with its own past self. The fixtures are therefore kept portable and
# free of engine-specific syntax.
#
# One knowing deviation, which the fixtures stay clear of so that regenerating
# never bakes in a wrong expectation: %o is specified to imply showHidden and
# depth 4, listing non-enumerable properties such as [length] and [prototype].
# This engine renders %o the same as %O. Plain arguments and %O match exactly.

# Two fixtures, both diffed the same way:
#
#   cases.js   hand-written, one case per rule, so a failure names the rule.
#   matrix.js  the cross product of container shape x element kind x size,
#              generated in the fixture itself. It covers combinations nobody
#              thought to write down, which is what catches a layout rule that
#              was inferred from too few shapes.
#
# Usage: bash test/console_format/run.sh [engine_binary]

ENGINE="${1:-./out/boomkat}"
DIR="$(cd "$(dirname "$0")" && pwd)"

total=0
for name in cases matrix; do
  got="$(timeout 30 "$ENGINE" "$DIR/$name.js" 2>&1)"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    # A regression here does not merely mis-print, it dies: before object
    # rendering existed the cyclic cases fell through to the trailing
    # space-separated append, where Array.prototype.toString recursed on the
    # self-reference until the stack went. So a segfault (139), or a timeout
    # (124) from a cycle that fails to terminate, is the expected shape of a
    # regression rather than a sign the fixture is broken.
    echo "FAIL: console_format ($name) — engine exited $rc"
    printf '%s\n' "$got" | head -5 | sed 's/^/      | /'
    echo "Console format: 0 passed, 1 failed"
    exit 1
  fi

  # A cyclic structure must terminate rather than recurse forever; the trailing
  # marker is what proves the run got past it.
  if [ "$(printf '%s\n' "$got" | tail -1)" != "done" ]; then
    echo "FAIL: console_format ($name) — output did not reach the final line"
    echo "Console format: 0 passed, 1 failed"
    exit 1
  fi

  if ! diff -u "$DIR/$name.expected.txt" <(printf '%s\n' "$got") > /tmp/console_format_diff.$$ 2>&1; then
    echo "FAIL: console_format ($name) — output differs from the captured expectations"
    head -30 /tmp/console_format_diff.$$ | sed 's/^/      | /'
    rm -f /tmp/console_format_diff.$$
    echo "Console format: 0 passed, 1 failed"
    exit 1
  fi
  rm -f /tmp/console_format_diff.$$

  total=$(( total + $(wc -l < "$DIR/$name.expected.txt" | tr -d ' ') ))
done

echo "Console format: $total lines matched reference"
exit 0
