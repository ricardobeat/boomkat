#!/usr/bin/env bash
# Every test/*.js and test/jit/*.js must print the same output and exit code under each JIT
# mode as in the interpreter, then opt_exit_check.sh must pass (QUICK=1 skips it).
#   scripts/jit_check.sh [BIN]
set -u
export BIN=${1:-./out/boomkat}
[ -x "$BIN" ] || { echo "jit-check: no binary $BIN"; exit 2; }
one() {
    run() { timeout 120 "$BIN" --memory-limit=512 "$@" --script "$f" 2>&1; echo "exit=$?"; }
    f=$1; ref=$(run)
    while IFS= read -r mode; do
        # shellcheck disable=SC2086
        [ "$ref" = "$(run $mode)" ] || echo "DIFF $f [$mode]"
    done <<'EOF'
--jit --no-opt
--jit --opt-always
EOF
}
export -f one
diffs=$(ls test/*.js test/jit/*.js | grep -v test_async_500k |
    xargs -P "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" -I{} bash -c 'one {}')
fails=$(grep -c '^DIFF' <<<"$diffs")
[ -n "$diffs" ] && echo "$diffs"
if [ "${QUICK:-0}" != 1 ]; then
    ex=$(scripts/opt_exit_check.sh 2>&1 | tail -1); echo "$ex"
    case "$ex" in *"fails=0"*) ;; *) fails=$((fails+1));; esac
fi
[ "$fails" = 0 ] && echo "jit-check OK" || { echo "jit-check FAIL $fails"; exit 1; }
