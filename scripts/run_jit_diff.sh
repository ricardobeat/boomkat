#!/bin/bash
# Differential JIT run: each suite through the interpreter and through the
# JIT under the stress setting, with the outputs compared. A difference is a
# tier fault; the suites' own assertions only cover what they assert.
#
# The stress setting (--jit-stress) compiles each function on its first call
# and never retires an entry, so the comparison exercises the compiler rather
# than the warmup policy. Timings in suite output are normalized away.
#
# Usage: bash scripts/run_jit_diff.sh [engine_binary]
#        bash scripts/run_jit_diff.sh --test262 [engine_binary]
#
# The --test262 mode compares test262 verdicts over language/expressions,
# language/statements and built-ins/Array instead of the local suites.
# Returns non-zero if any comparison differs.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="suites"
if [ "${1:-}" = "--test262" ]; then MODE="test262"; shift; fi
ENGINE="${1:-$([ "$MODE" = "test262" ] && echo ./out/test262_runner || echo ./out/boomkat)}"
case "$ENGINE" in /*) ;; *) ENGINE="$ROOT/$ENGINE" ;; esac
if [ ! -x "$ENGINE" ]; then echo "no engine at $ENGINE"; exit 2; fi
TMP="${TMPDIR:-/tmp}/jit-diff.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/interp" <<EOF
#!/bin/sh
exec "$ENGINE" "\$@"
EOF
cat > "$TMP/jit" <<EOF
#!/bin/sh
exec "$ENGINE" --jit --jit-stress "\$@"
EOF
chmod +x "$TMP/interp" "$TMP/jit"

normalize() { sed -E 's/[0-9]+(\.[0-9]+)? ?ms/N ms/g'; }

cd "$ROOT"
rc=0
compare() {
    name="$1"
    a="$2"
    b="$3"
    if [ "$4" -ne "$5" ]; then
        echo "$name: exit status differs (interpreter $4, jit $5)"
        rc=1
    fi
    if ! diff -u "$a" "$b" > "$TMP/$name.diff"; then
        echo "$name: output differs"
        head -40 "$TMP/$name.diff"
        rc=1
    elif [ "$4" -eq "$5" ]; then
        echo "$name: match (status $4)"
    fi
}

run_suite() {
    name="$1"; shift
    "$@" "$TMP/interp" > "$TMP/$name.interp" 2>&1
    a=$?
    "$@" "$TMP/jit" > "$TMP/$name.jit" 2>&1
    b=$?
    normalize < "$TMP/$name.interp" > "$TMP/$name.interp.n"
    normalize < "$TMP/$name.jit" > "$TMP/$name.jit.n"
    compare "$name" "$TMP/$name.interp.n" "$TMP/$name.jit.n" "$a" "$b"
}

run_test262() {
    d="$1"
    name="t262-$(echo "$d" | tr '/' '-')"
    TEST262_VM_BINARY="$ENGINE" python3 scripts/run_test262.py --dir "$d" \
        --log "$TMP/$name.interp.tsv" > "$TMP/$name.interp" 2>&1
    a=$?
    TEST262_VM_BINARY="$TMP/jit" python3 scripts/run_test262.py --dir "$d" \
        --log "$TMP/$name.jit.tsv" > "$TMP/$name.jit" 2>&1
    b=$?
    sort "$TMP/$name.interp.tsv" > "$TMP/$name.interp.s"
    sort "$TMP/$name.jit.tsv" > "$TMP/$name.jit.s"
    compare "$name" "$TMP/$name.interp.s" "$TMP/$name.jit.s" "$a" "$b"
}

if [ "$MODE" = "test262" ]; then
    run_test262 language/expressions
    run_test262 language/statements
    run_test262 built-ins/Array
else
    run_suite test-local bash "$ROOT/test/run_local.sh"
    run_suite rosetta bash "$ROOT/test/rosetta-verbatim/run.sh"
    run_suite modules bash "$ROOT/test/modules/run.sh"
fi
exit $rc
