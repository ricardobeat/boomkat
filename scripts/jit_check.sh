#!/usr/bin/env bash
# Fast JIT validation. For every test/*.js and test/jit/*.js the stdout+stderr+exit code under
# --jit, --jit --opt, --jit --opt --opt-always, the same with a 20 KB optimized-code cap
# (eviction), --jit --opt --jit-stress (every function compiled on first call) and every loop
# compiled as a region (--opt-region-always --opt-always) must equal the interpreter's (the interpreter
# runs once per file); then the optimizing-tier exit check (scripts/opt_exit_check.sh, skipped
# with QUICK=1). Prints "jit-check OK" or "jit-check FAIL n" plus the diffs.
#   scripts/jit_check.sh [BIN]    BIN defaults to ./out/boomkat; JOBS defaults to the core count.
# No ASan, no GC-stress. Check the printed binary mtime: a stale binary has misled us before.
set -u
BIN=${1:-./out/boomkat}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/jitcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
[ -x "$BIN" ] || { echo "jit-check: no binary $BIN"; exit 2; }
echo "jit-check: $BIN, built $(stat -f '%Sm' "$BIN" 2>/dev/null || stat -c %y "$BIN"), $JOBS jobs"
start=$(date +%s)
# The JIT modes each file is compared under, semicolon-separated so the function below can be
# exported and still split them.
MODES="--jit;--jit --opt;--jit --opt --opt-always;--jit --opt --opt-always --opt-code-max=20000;--jit --opt --jit-stress;--jit --opt --opt-region-always --opt-always"
export MODES
nmode=$(( $(printf '%s' "$MODES" | tr -cd ';' | wc -c) + 1 ))
one() {
    f=$1
    ref=$(timeout 60 "$BIN" --memory-limit=512 --script "$f" 2>&1; echo "exit=$?")
    for mode in ${MODES//;/ }; do
        # shellcheck disable=SC2086
        out=$(timeout 120 "$BIN" --memory-limit=512 $mode --script "$f" 2>&1; echo "exit=$?")
        [ "$ref" = "$out" ] || echo "DIFF $f [$mode]"
    done
}
export -f one; export BIN
ls test/*.js test/jit/*.js | grep -v test_async_500k > "$TMP/files"
n=$(wc -l < "$TMP/files" | tr -d ' ')
xargs -P "$JOBS" -I{} bash -c 'one {}' < "$TMP/files" > "$TMP/diffs" 2>&1
fails=$(grep -c '^DIFF' "$TMP/diffs"); fails=${fails:-0}
echo "jit-check: $n files x $nmode modes in $(( $(date +%s) - start ))s, $fails diffs"
cat "$TMP/diffs"
if [ "${QUICK:-0}" != 1 ]; then
    s2=$(date +%s)
    ex=$(BIN="$BIN" scripts/opt_exit_check.sh 2>&1 | tail -1)
    echo "$ex ($(( $(date +%s) - s2 ))s)"
    case "$ex" in *"fails=0"*) ;; *) fails=$((fails+1));; esac
fi
if [ "$fails" = 0 ]; then echo "jit-check OK"; else echo "jit-check FAIL $fails"; exit 1; fi
