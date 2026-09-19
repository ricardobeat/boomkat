#!/usr/bin/env bash
# Run every test262 file under DIR through the HEAP_VERIFY runner and fail if
# any of them reports a frame popped with heap slots still in it.
#
# The verifier prints "[vm] pop at <site> left heap slot rN" at the moment the
# invariant breaks. Without it the same bug surfaces as a stale register
# dispatched as a callee ("<typeof> is not a function") in a later frame, or as
# nothing at all until a different test in the same worker crashes.
set -uo pipefail

DIR="${1:-staging/sm/Number}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=out/test262_runner_verify
[ -x "$BIN" ] || { echo "missing $BIN (run: just build-verify)" >&2; exit 2; }

BASE="test262/test/$DIR"
[ -d "$BASE" ] || { echo "no such directory: $BASE" >&2; exit 2; }

mapfile -t FILES < <(find "$BASE" -name '*.js' ! -name '*_FIXTURE*' | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "no tests under $BASE" >&2; exit 2; }

echo "verifying ${#FILES[@]} test(s) under $DIR"
log=$(mktemp)
trap 'rm -f "$log"' EXIT

# One worker process, fed every path: this is also what exercises the
# cross-test contamination the verifier is there to catch.
printf '%s\n' "${FILES[@]}" | "$BIN" --worker > "$log" 2>&1
rc=$?

fail=0

# A frame popped with a slot pointing at reclaimed memory: the invariant broke
# here, whatever reads it later.
if grep -q '^\[vm\] ' "$log"; then
    echo "HEAP VERIFY FAILURES:" >&2
    grep '^\[vm\] ' "$log" | sort | uniq -c | sort -rn >&2
    fail=1
fi

# ASan aborts the process on the first bad read, which can happen before any
# [vm] line is printed -- that is itself the finding, so surface it rather than
# reporting success on a run that died.
if grep -q 'ERROR: AddressSanitizer' "$log"; then
    echo "ADDRESSSANITIZER:" >&2
    grep -A 4 'ERROR: AddressSanitizer' "$log" | head -20 >&2
    fail=1
fi

if [ "$rc" -ne 0 ]; then
    echo "runner exited $rc" >&2
    fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "no heap-verify reports"
