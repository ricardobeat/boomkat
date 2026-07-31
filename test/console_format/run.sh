#!/bin/bash
# console format-specifier substitution (%s %d %i %f %o %O %j %c).
#
# Its own surface because what is under test is what console WRITES to stdout,
# which a script in the flat test/*.js sweep cannot observe about itself. So the
# fixture prints and this driver diffs the whole stream against expected.txt.
#
# REFERENCE: node's util.format, not the bare WHATWG console Formatter — the
# two disagree on %j (WHATWG has none), on %o detail, and on %c (WHATWG applies
# CSS; node ignores the directive but still consumes its argument). Node is the
# useful target because real code is written against it.
#
# expected.txt IS NODE'S OUTPUT, captured verbatim with:
#
#     node test/console_format/cases.js > test/console_format/expected.txt
#
# so it can be re-derived and audited at any time. cases.js is therefore kept
# runnable by node: it must stay free of engine-specific syntax, and it stays
# clear of the two places this engine knowingly differs from node, so that
# regenerating never bakes in a wrong expectation:
#
#   - util.inspect rendering. Node prints an object as "{ a: 1 }" and a bare
#     -0 as "-0"; this engine has no inspect and prints "[object Object]" / "0"
#     for plain arguments too. That gap predates specifier support, so %o/%O
#     and object-valued %s are out of scope here.
#   - BigInt's "n" suffix. Node prints 10n, this engine prints 10, again for
#     plain arguments too.
#
# Usage: bash test/console_format/run.sh [engine_binary]

ENGINE="${1:-./out/duktape_c3}"
DIR="$(cd "$(dirname "$0")" && pwd)"

got="$(timeout 30 "$ENGINE" "$DIR/cases.js" 2>&1)"
rc=$?

if [ "$rc" -ne 0 ]; then
  # An engine without specifier support does not merely mis-print here, it dies:
  # the cyclic-array case falls through to the trailing space-separated append,
  # where Array.prototype.toString recurses on the self-reference until the
  # stack goes. So a segfault (139) is the expected shape of a regression, not a
  # sign the fixture itself is broken.
  echo "FAIL: console_format — engine exited $rc"
  printf '%s\n' "$got" | head -5 | sed 's/^/      | /'
  echo "Console format: 0 passed, 1 failed"
  exit 1
fi

# A cyclic structure under %j must terminate rather than recurse forever; the
# trailing marker is what proves the run got past it.
if [ "$(printf '%s\n' "$got" | tail -1)" != "done" ]; then
  echo "FAIL: console_format — output did not reach the final line"
  echo "Console format: 0 passed, 1 failed"
  exit 1
fi

if ! diff -u "$DIR/expected.txt" <(printf '%s\n' "$got") > /tmp/console_format_diff.$$ 2>&1; then
  echo "FAIL: console_format — output differs from node's captured expectations"
  head -30 /tmp/console_format_diff.$$ | sed 's/^/      | /'
  rm -f /tmp/console_format_diff.$$
  echo "Console format: 0 passed, 1 failed"
  exit 1
fi
rm -f /tmp/console_format_diff.$$

lines="$(wc -l < "$DIR/expected.txt" | tr -d ' ')"
echo "Console format: $lines lines matched node"
exit 0
