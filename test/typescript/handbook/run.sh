#!/bin/bash
# TypeScript handbook syntax corpus: small, doc-organized .ts files, one TS
# feature area per file, covering the erasable subset the engine accepts.
#
# Each accept file (tNN_*.ts) is executed under node, whose native type
# stripping is the reference runtime, and the engine must match that stdout
# byte for byte and exit 0. The reference outputs are captured in .expected
# files so the gate has no runtime dependency on node; regenerate them with:
#
#     bash test/typescript/handbook/run.sh --regen
#
# Reject files (rNN_*_reject.ts) name syntax that is NOT erasable (enums,
# namespaces, parameter properties, angle-bracket assertions). Both tsc
# (--erasableSyntaxOnly, TS1294) and node's type stripping refuse them, so
# the engine must refuse to compile them too: non-zero exit is the pass
# condition.
#
# Usage: bash test/typescript/handbook/run.sh [engine_binary] [--regen]

set -u
ENGINE="${ENGINE:-./out/duktape_c3}"
REGEN=0
for arg in "$@"; do
  case "$arg" in
    --regen) REGEN=1 ;;
    *) ENGINE="$arg" ;;
  esac
done
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
FAILED_NAMES=()

for f in "$DIR"/t*.ts; do
  name="$(basename "$f")"
  expected_file="${f%.ts}.expected"

  if [ "$REGEN" -eq 1 ]; then
    node "$f" > "$expected_file" 2>/tmp/handbook_node_err.$$ || {
      echo "REGEN ABORT: node rejected $name"
      cat /tmp/handbook_node_err.$$ | head -5
      rm -f /tmp/handbook_node_err.$$
      exit 1
    }
    rm -f /tmp/handbook_node_err.$$
    continue
  fi

  [ -f "$expected_file" ] || { echo "FAIL: $name (no .expected file; run with --regen)"; FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name"); continue; }

  got="$(timeout 30 "$ENGINE" "$f" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: $name (engine exited $rc)"
    printf '%s\n' "$got" | head -4 | sed 's/^/      | /'
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name"); continue
  fi
  # Both sides go through $( ) so trailing newlines are stripped uniformly;
  # a dependency module with no output then compares equal to an empty run.
  if [ "$(printf '%s\n' "$got")" != "$(printf '%s\n' "$(cat "$expected_file")")" ]; then
    echo "FAIL: $name (output differs from node reference)"
    diff <(cat "$expected_file") <(printf '%s\n' "$got") | head -12 | sed 's/^/      | /'
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name"); continue
  fi
  PASS=$((PASS + 1))
done

if [ "$REGEN" -eq 1 ]; then
  echo "Regenerated reference outputs from node."
  exit 0
fi

for f in "$DIR"/r*_reject.ts; do
  name="$(basename "$f")"
  got="$(timeout 30 "$ENGINE" "$f" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL: $name (expected a compile rejection, engine accepted it)"
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name"); continue
  fi
  PASS=$((PASS + 1))
done

echo "Handbook TS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || printf 'failed: %s\n' "${FAILED_NAMES[*]}"
[ "$FAIL" -eq 0 ]
