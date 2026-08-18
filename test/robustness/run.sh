#!/bin/bash
# Resource-limit robustness: the engine must refuse, not die.
#
# This is its own surface because the failures under test are abnormal process
# exits — a SIGSEGV or a hang — which the flat test/*.js sweep cannot express:
# a crashing fixture has no output to assert, and a hanging one never returns.
#
# The invariant: exceeding an internal limit produces a catchable JS error and
# a normal exit. Signals (SIGSEGV/SIGBUS/SIGABRT, exit >= 128) and timeouts are
# failures. An engine meant for embedding must never take its host process down
# on input it merely dislikes, and must never become unkillable from inside.
#
# Usage: bash test/robustness/run.sh [engine_binary]

ENGINE="${1:-./out/boomkat}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check_clean <name> <timeout-seconds> <source>
# Passes when the engine exits without a signal and without timing out. Both a
# clean run and a reported JS error are acceptable; dying is not.
check_clean() {
  local name="$1" secs="$2" src="$3"
  printf '%s\n' "$src" > "$TMP/t.js"
  local got rc
  got="$(timeout "$secs" "$ENGINE" "$TMP/t.js" 2>&1)"
  rc=$?

  if [ "$rc" -eq 124 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — timed out after ${secs}s (hang)"; return
  fi
  if [ "$rc" -ge 128 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $name — killed by signal $((rc - 128)) (crash)"
    return
  fi
  if printf '%s' "$got" | grep -q "VM error"; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — reported an internal VM fault: $got"; return
  fi
  PASS=$((PASS + 1))
}

# check_catchable <name> <timeout-seconds> <source>
# Stronger form: the limit must surface as a JS exception the script itself can
# catch, so an embedder can recover rather than lose the runtime.
check_catchable() {
  local name="$1" secs="$2" body="$3"
  printf 'try { %s\n print("NOTHROW"); } catch (e) { print("CAUGHT:" + (e && e.constructor && e.constructor.name)); }\n' \
    "$body" > "$TMP/t.js"
  local got rc
  got="$(timeout "$secs" "$ENGINE" "$TMP/t.js" 2>&1)"
  rc=$?

  if [ "$rc" -eq 124 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — timed out after ${secs}s (hang)"; return
  fi
  if [ "$rc" -ge 128 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — killed by signal $((rc - 128)) (crash)"; return
  fi
  case "$got" in
    CAUGHT:*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); echo "FAIL: $name — expected a catchable error, got '$got'" ;;
  esac
}

# --- string length overflow -------------------------------------------------
# Doubling a string 40 times passed 2**31 and then segfaulted (exit 139). The
# length must be bounded and the overflow reported, as QuickJS does with
# "InternalError: string too long".
check_clean "string doubling to overflow" 60 \
  'var s = "x"; for (var i = 0; i < 40; i++) { s += s; } print(s.length);'
check_catchable "string doubling is catchable" 60 \
  'var s = "x"; for (var i = 0; i < 40; i++) { s += s; }'
check_catchable "concat past the limit is catchable" 60 \
  'var a = "x".repeat(1 << 30); var b = a + a + a + a;'

# --- deep recursion ---------------------------------------------------------
# Already correct (RangeError, no native stack overflow); guarded so a change
# to the frame layout cannot silently turn it into a segfault.
check_catchable "unbounded recursion" 30 \
  'function r(n) { return n <= 0 ? 0 : 1 + r(n - 1); } r(10000000);'
check_catchable "unbounded mutual recursion" 30 \
  'function a(n){ return b(n+1); } function b(n){ return a(n+1); } a(0);'

# --- deeply nested source ---------------------------------------------------
# Compile-time nesting must not overflow the parser's native stack.
check_clean "deeply nested array literal" 30 \
  "var x = $(python3 -c 'print("["*5000 + "]"*5000)'); print(\"ok\");"
check_clean "deeply nested parens" 30 \
  "var x = $(python3 -c 'print("("*2000 + "1" + ")"*2000)'); print(\"ok\");"

# --- pathological runtime structures ---------------------------------------
check_catchable "recursive proxy get trap" 20 \
  'var p = new Proxy({}, { get: function(t, k) { return p[k]; } }); p.x;'
check_clean "huge sparse array index" 20 \
  'var a = []; a[4294967294] = 1; print(a.length);'

echo ""
echo "Robustness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
