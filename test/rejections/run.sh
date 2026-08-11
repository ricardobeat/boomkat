#!/bin/bash
# Unhandled promise rejections must be reported.
#
# Its own surface for the same reason as test/uncaught/: what is under test is
# the CLI's REPORTING and exit status, not a value a script computes. A script
# cannot assert its own silent death.
#
# The invariant: a rejection that reaches the end of the microtask drain with
# no handler is reported on stderr and exits non-zero. Silence loses every
# async failure — a `throw` inside an async function or a `.then` simply
# vanishes, which is the failure mode this suite exists to prevent.
#
# QuickJS prints "Possibly unhandled promise rejection: <value>" and exits 1;
# node prints a similar warning and exits 1. This engine exited 0 with no
# output at all. See plans/070-real-world-battle-testing.md.
#
# Usage: bash test/rejections/run.sh [engine_binary]

ENGINE="${1:-./out/duktape_c3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# reported <name> <source> <substring-that-must-appear>
# The exact wording is not pinned; what matters is that the failure is visible
# and the exit status is non-zero.
reported() {
  local name="$1" src="$2" want="$3"
  printf '%s\n' "$src" > "$TMP/t.js"
  local got rc
  got="$(timeout 30 "$ENGINE" "$TMP/t.js" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $name — exited 0, rejection was swallowed (output: '$got')"
    return
  fi
  if [ "$rc" -ge 128 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — killed by signal $((rc - 128))"; return
  fi
  case "$got" in
    *"$want"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1))
       echo "FAIL: $name — expected output containing '$want', got '$got'" ;;
  esac
}

# silent <name> <source>
# The complement: a rejection that IS handled must stay quiet and exit 0, so
# the reporting cannot be implemented by shouting about every rejection.
silent() {
  local name="$1" src="$2"
  printf '%s\n' "$src" > "$TMP/t.js"
  local got rc
  got="$(timeout 30 "$ENGINE" "$TMP/t.js" 2>&1)"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — expected exit 0, got $rc ('$got')"; return
  fi
  case "$got" in
    *ejection*|*nhandled*)
      FAIL=$((FAIL + 1))
      echo "FAIL: $name — reported a rejection that was handled: '$got'" ;;
    *) PASS=$((PASS + 1)) ;;
  esac
}

# --- rejections that must be reported --------------------------------------
reported "bare Promise.reject" \
  'Promise.reject(new Error("boom"));' "boom"
reported "throw inside async function" \
  'async function f(){ throw new Error("async boom"); } f();' "async boom"
reported "throw inside .then" \
  'Promise.resolve().then(function(){ throw new Error("then boom"); });' "then boom"
reported "rejection after await" \
  '(async function(){ await null; throw new Error("post await"); }());' "post await"
reported "reject with a string" \
  'Promise.reject("plain string");' "plain string"
reported "unhandled in a chain" \
  'Promise.resolve().then(function(){ return Promise.reject(new Error("chain")); });' "chain"

# --- rejections that are handled and must stay silent ----------------------
silent "catch handler present" \
  'Promise.reject(new Error("x")).catch(function(){});'
silent "then with a rejection handler" \
  'Promise.reject(new Error("x")).then(null, function(){});'
silent "try/catch around await" \
  '(async function(){ try { await Promise.reject(new Error("x")); } catch (e) {} }());'
silent "handler attached later in the same tick" \
  'var p = Promise.reject(new Error("x")); p.catch(function(){});'
silent "resolved promise" \
  'Promise.resolve(1).then(function(){});'

echo ""
echo "Rejection reporting: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
