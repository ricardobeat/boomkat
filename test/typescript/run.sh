#!/usr/bin/env bash
# Run the TypeScript erasable-subset corpus and diff outputs.
# Exits non-zero on any failure.
set -uo pipefail

BIN="${BIN:-./out/test_vm}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

expect_ok() {
    local file="$1" want="$2"
    local got
    got=$("$BIN" "$file" 2>&1)
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $file"
        echo "  want: $(printf '%q' "$want")"
        echo "  got:  $(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    else
        echo "ok:   $(basename "$file")"
    fi
}

expect_reject() {
    local file="$1" pattern="$2"
    local got rc
    got=$("$BIN" "$file" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "FAIL: $file (expected rejection, got success)"
        FAIL=$((FAIL + 1))
    elif ! grep -q -- "$pattern" <<<"$got"; then
        echo "FAIL: $file"
        echo "  pattern: $pattern"
        echo "  got:     $got"
        FAIL=$((FAIL + 1))
    else
        echo "ok:   $(basename "$file") (rejected)"
    fi
}

expect_ok "$DIR/simple.ts"    "42"
expect_ok "$DIR/basic.ts"     "hello world hello world 
42"
expect_ok "$DIR/fn.ts"        "5"
expect_ok "$DIR/generics.ts"  "42
hi"
expect_ok "$DIR/erasable.ts"  "hello
1
3
on:42
off:x"
expect_ok "$DIR/klass.ts"     "hello, world
impl"
expect_ok "$DIR/source_pos.ts" "BOOM@line5"

expect_reject "$DIR/reject_enum.ts"      "not erasable syntax"
expect_reject "$DIR/reject_namespace.ts" "not erasable syntax"

if [[ $FAIL -eq 0 ]]; then
    echo "== all TS tests passed =="
    exit 0
fi
echo "== $FAIL TS test(s) failed =="
exit 1
