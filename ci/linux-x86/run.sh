#!/usr/bin/env bash
# Linux/amd64 build + test suite, run INSIDE the image built from
# ci/linux-x86/Dockerfile. Drive it from the host with `make linux-x86-ci`.
#
# This mirrors the x86-64 GitHub CI: build the engine, run the local test suite,
# and run the test262 zero-fail gate. It exists to reproduce x86-64-specific
# failures on an Apple Silicon host, so it deliberately runs the same scripts CI
# and `just` do rather than reimplementing them.
#
# Every phase prints PASS/FAIL on its own line and the script exits non-zero if
# any phase failed. Usage: bash ci/linux-x86/run.sh [phase ...] (default: all).

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

RESULTS=()
FAILED=0
TIMEOUT="${TIMEOUT:-1800}"

say()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
pass() { RESULTS+=("PASS  $*"); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { RESULTS+=("FAIL  $*"); FAILED=1; printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { RESULTS+=("SKIP  $*"); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }

PHASES=("$@")
want() {
    [ ${#PHASES[@]} -eq 0 ] && return 0
    local p; for p in "${PHASES[@]}"; do [ "$p" = "$1" ] && return 0; done
    return 1
}

say "environment"
printf 'arch   : %s\n' "$(uname -m)"
printf 'kernel : %s\n' "$(uname -sr)"
printf 'c3c    : %s\n' "$(c3c --version 2>&1 | awk '/Compiler Version/{print $4}')"
printf 'cc     : %s\n' "$(cc --version | head -1)"

# The bind-mounted working tree may carry macOS build artifacts in out/ and the
# c3c build cache. A stale Mach-O archive fails the x86-64 build in confusing
# ways, so clear them before the first build phase.
if want build; then
    say "1. build engine + test262 runner (clean out/ first)"
    rm -rf out build
    if timeout "$TIMEOUT" make boomkat 2>&1 | tail -3 && [ -x out/boomkat ]; then
        pass "engine binary built"
    else
        fail "engine build"
    fi
    if timeout "$TIMEOUT" make out/test262_runner 2>&1 | tail -3 && [ -x out/test262_runner ]; then
        pass "test262 runner built"
    else
        fail "test262 runner build"
    fi
fi

if want tests; then
    say "2. engine test suite (bash test/run_local.sh)"
    if [ ! -x out/boomkat ]; then
        skip "test suite (no engine binary)"
    else
        log=$(mktemp)
        timeout "$TIMEOUT" bash test/run_local.sh >"$log" 2>&1
        rc=$?
        grep -E 'passed|matched reference|^FAIL' "$log" | tail -20
        [ $rc -eq 0 ] && pass "test suite (exit 0)" || fail "test suite (exit $rc)"
        rm -f "$log"
    fi
fi

if want test262; then
    say "3. test262 zero-fail gate (bash scripts/test262_gate.sh)"
    if [ ! -d test262/test ]; then
        skip "test262 (submodule test262/ not checked out)"
    elif [ ! -x out/test262_runner ]; then
        skip "test262 (no runner binary)"
    else
        log=$(mktemp)
        timeout 3600 bash scripts/test262_gate.sh >"$log" 2>&1
        rc=$?
        grep -E '^Overall \(raw\):|GATE (PASSED|FAILED)|FAIL ' "$log" | tail -30
        [ $rc -eq 0 ] && pass "test262 gate (0 fail)" || fail "test262 gate (exit $rc)"
        rm -f "$log"
    fi
fi

say "summary"
printf '%s\n' "${RESULTS[@]}"
printf '\n%d phase result(s), overall: %s\n' "${#RESULTS[@]}" \
    "$([ $FAILED -eq 0 ] && echo PASS || echo FAIL)"
exit $FAILED
