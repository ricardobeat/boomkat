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

# --- original corpus -------------------------------------------------------
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

# --- expanded corpus (25 tests, various aspects) --------------------------
expect_ok "$DIR/union.ts"              "two"
expect_ok "$DIR/intersection.ts"       "1
x"
expect_ok "$DIR/overloads.ts"          "hi a
hi b 3"
expect_ok "$DIR/type_alias_generic.ts" "7"
expect_ok "$DIR/interface_extends.ts"  "a
1
x"
expect_ok "$DIR/destructure_obj.ts"    "1
two"
expect_ok "$DIR/destructure_arr.ts"    "60"
expect_ok "$DIR/rest_param.ts"         "10"
expect_ok "$DIR/default_params.ts"     "hi world
hi x
hey x"
expect_ok "$DIR/arrow_ret.ts"          "10
ab"
expect_ok "$DIR/arrow_generic.ts"      "42
hi"
expect_ok "$DIR/async_type.ts"         "42"
expect_ok "$DIR/catch_unknown.ts"      "boom"
expect_ok "$DIR/optional_chain.ts"     "42
yes"
expect_ok "$DIR/as_const.ts"           "1
two
true"
expect_ok "$DIR/nonnull.ts"            "5"
expect_ok "$DIR/satisfies.ts"          "localhost
80"
expect_ok "$DIR/generic_method.ts"     "3
hi"
expect_ok "$DIR/multi_impl.ts"         "42
b!"
expect_ok "$DIR/for_of_typed.ts"       "6"
expect_ok "$DIR/string_union.ts"       "1
-1"
expect_ok "$DIR/nested_generic.ts"     "1
two"
expect_ok "$DIR/type_import.ts"        "99"
expect_ok "$DIR/recursive_type.ts"     "6"
expect_ok "$DIR/optional_param.ts"     "a
b#2"

# --- rejects ---------------------------------------------------------------
expect_reject "$DIR/reject_enum.ts"       "not erasable syntax"
expect_reject "$DIR/reject_namespace.ts"  "not erasable syntax"
expect_reject "$DIR/reject_ctor_prop.ts"  "public"

# --- tsc oracle (optional) -------------------------------------------------
# If tsc is on PATH, cross-check the corpus against `--erasableSyntaxOnly`:
#   1. `tsc -p .` (accepting corpus + tsconfig excludes) must pass with no error.
#   2. Each reject file must fail with TS1294 (erasableSyntaxOnly violation).
if command -v tsc >/dev/null 2>&1; then
    echo "== tsc oracle =="
    if (cd "$DIR" && tsc -p . >/tmp/tsc.out 2>&1); then
        echo "ok:   tsc accepts corpus"
    else
        echo "FAIL: tsc rejected the accepting corpus:"
        cat /tmp/tsc.out
        FAIL=$((FAIL + 1))
    fi
    for rej in reject_enum.ts reject_namespace.ts reject_ctor_prop.ts; do
        out=$(cd "$DIR" && tsc --ignoreConfig --erasableSyntaxOnly --noEmit \
              --isolatedModules --target es2022 --module esnext --lib es2022 \
              --skipLibCheck --strict false --moduleDetection force \
              --types "" "$rej" 2>&1)
        if grep -q TS1294 <<<"$out"; then
            echo "ok:   tsc rejects $rej (TS1294)"
        else
            echo "FAIL: tsc did not flag $rej with TS1294"
            echo "$out"
            FAIL=$((FAIL + 1))
        fi
    done
else
    echo "-- tsc not on PATH; skipping oracle cross-check"
fi

if [[ $FAIL -eq 0 ]]; then
    echo "== all TS tests passed =="
    exit 0
fi
echo "== $FAIL TS test(s) failed =="
exit 1
