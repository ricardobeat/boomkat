#!/bin/bash
# Uncaught-exception reporting on the plain runner's stderr.
#
# This is its own surface because these cases are, by construction, non-zero
# exits with diagnostics on stderr — the flat test/*.js sweep would read every
# one of them as a failure. What is under test is the CLI's REPORTING, not a
# value the engine computes, so it is asserted from the shell.
#
# `throw` accepts any value, and a thrown non-Error (a bare string, a number, a
# plain object with no `.message`) used to fall through to the internal-fault
# wording "VM error: vm::VM_ERROR (at execute)". That misdescribed an ordinary
# JS-level throw as an engine crash, and it burned the one phrase that signals
# a genuine internal fault, so real engine bugs hid among ordinary throws.
#
# The invariant: an uncaught throw prints exactly ONE line, "Uncaught: <value>",
# and exits 1. "VM error:" is reserved for an internal fault with no JS error
# attached and must never appear for a JS-level throw.
#
# Usage: bash test/uncaught/run.sh [engine_binary]

ENGINE="${1:-./out/boomkat}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check <name> <source> <expected-stderr-line>
check() {
  local name="$1" src="$2" want="$3"
  printf '%s\n' "$src" > "$TMP/t.js"
  local got rc lines
  got="$(timeout 30 "$ENGINE" "$TMP/t.js" 2>&1)"
  rc=$?
  lines="$(printf '%s\n' "$got" | grep -c .)"

  if [ "$rc" -ne 1 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — expected exit 1, got $rc"; return
  fi
  if [ "$lines" -ne 1 ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — expected 1 line, got $lines: $got"; return
  fi
  if [ "$got" != "$want" ]; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — want '$want', got '$got'"; return
  fi
  if printf '%s' "$got" | grep -q "VM error"; then
    FAIL=$((FAIL + 1)); echo "FAIL: $name — a JS throw reported as an internal VM fault"; return
  fi
  PASS=$((PASS + 1))
}

# Error objects and engine-raised errors (the cases that already worked —
# guarding them keeps the fix from regressing the common path).
check "throw Error"       'throw new Error("msg");' \
      "Uncaught: msg"
check "engine TypeError"  'null.x;' \
      "Uncaught: Cannot read properties of null (reading 'x')"

# Thrown non-Errors: each of these printed "VM error: ..." before the fix.
check "throw string"      'throw "a string";'  "Uncaught: a string"
check "throw int"         'throw 42;'          "Uncaught: 42"
check "throw double"      'throw 3.5;'         "Uncaught: 3.5"
check "throw true"        'throw true;'        "Uncaught: true"
check "throw null"        'throw null;'        "Uncaught: null"
check "throw undefined"   'throw undefined;'   "Uncaught: undefined"
check "throw bare object" 'throw {nomsg:1};'   "Uncaught: [object]"
check "throw array"       'throw [1,2];'       "Uncaught: [object]"

# A throw escaping a sync function called from a nested frame still unwinds to
# the same top-level reporting path.
check "throw from nested"  'function g(){ throw "deep"; } function f(){ g(); } f();' \
      "Uncaught: deep"
# A rethrow out of catch, and a throw from a finally block.
check "rethrow from catch"  'try { throw 1; } catch (e) { throw "re:" + e; }' \
      "Uncaught: re:1"

# A LIVE MICROTASK QUEUE must not change any of the above. With a pending
# microtask, every one of these used to collapse onto
# "VM error: vm::VM_ERROR (at execute)" — the error was formed correctly and
# then lost on the unwind path, so the reporting regressed exactly where real
# async programs live. Same invariant as the block above, plus a pending job.
check "microtask + throw Error" \
      'Promise.resolve().then(function(){}); throw new Error("msg");' \
      "Uncaught: msg"
check "microtask + engine TypeError" \
      'Promise.resolve().then(function(){}); null.x;' \
      "Uncaught: Cannot read properties of null (reading 'x')"
check "microtask + ReferenceError" \
      'Promise.resolve().then(function(){}); missingGlobalName;' \
      "Uncaught: missingGlobalName is not defined"
check "microtask + throw string" \
      'Promise.resolve().then(function(){}); throw "a string";' \
      "Uncaught: a string"
check "microtask + throw from nested" \
      'Promise.resolve().then(function(){}); function g(){ throw "deep"; } function f(){ g(); } f();' \
      "Uncaught: deep"
check "async fn pending + throw" \
      '(async function(){ await null; }()); throw new Error("msg");' \
      "Uncaught: msg"

# NOT covered here: an unhandled PROMISE REJECTION (`async function f(){ throw
# "x"; } f();`) is silently ignored and exits 0 — node reports it. That is a
# separate, pre-existing gap in rejection tracking, not part of this reporting
# path, which only sees exceptions that unwind to the top level synchronously.
# Its own coverage is in test/rejections/run.sh.

echo ""
echo "Uncaught reporting: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
