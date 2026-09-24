#!/usr/bin/env bash
# Run every test262 file under one or more DIRs through the HEAP_VERIFY runner,
# all of them fed to a single worker, and fail if it reports a broken heap
# invariant.
#
# One worker for the whole shard is the point: the invariants behind these
# reports are about state that outlives a single test, so a fresh process per
# test would hide them. A stale register, a recycled allocator block, or a scope
# the previous test left behind only shows up when the next test runs on top of
# it.
#
# Reports that fail the gate:
#   [vm] ...           a frame popped with a heap slot still pointing at it, or
#                      a value released while a live register still holds it
#   [scan-poison] ...  the marker reached a slot no writer filled, or one whose
#                      owner was freed (SCAN_POISON is on in this build)
#   ERROR: AddressSanitizer
#                      a bad read that aborted the worker before a report
#
# Leak reports are off by default: this gate is about invalidity, and the tree
# has long-standing leaks that other checks track (see scripts/run_heap_reset.sh
# and scripts/check_temproot_rss.py). Set ASAN_OPTIONS to override.
#
# Usage: bash scripts/test262_verify.sh [dir ...]   (paths under test262/test)
set -uo pipefail

DIRS=("$@")
[ "${#DIRS[@]}" -gt 0 ] || DIRS=("built-ins/TypedArray/prototype")

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN=out/test262_runner_verify
[ -x "$BIN" ] || { echo "missing $BIN (run: just build-test262-verify)" >&2; exit 2; }

FILES=()
for d in "${DIRS[@]}"; do
    BASE="test262/test/$d"
    [ -d "$BASE" ] || { echo "no such directory: $BASE" >&2; exit 2; }
    while IFS= read -r f; do FILES+=("$f"); done \
        < <(find "$BASE" -name '*.js' ! -name '*_FIXTURE*' | sort)
done

[ "${#FILES[@]}" -gt 0 ] || { echo "no tests under ${DIRS[*]}" >&2; exit 2; }

echo "verifying ${#FILES[@]} test(s) under ${DIRS[*]}"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

printf '%s\n' "${FILES[@]}" \
    | ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}" "$BIN" --worker > "$log" 2>&1
rc=$?

fail=0

for pat in '^\[vm\] ' '^\[scan-poison\] '; do
    if grep -q "$pat" "$log"; then
        echo "HEAP VERIFY FAILURES (${pat}):" >&2
        grep "$pat" "$log" | sort | uniq -c | sort -rn >&2
        fail=1
    fi
done

# ASan aborts the process on the first bad read, which can happen before any
# report line is printed -- that is itself the finding, so surface it rather
# than reporting success on a run that died.
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
