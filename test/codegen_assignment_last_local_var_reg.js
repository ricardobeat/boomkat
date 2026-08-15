// Coverage for the assignment-result / last_local_var_reg pairing.
//
// assignment_expr's two result paths (simple `=` and compound `op=`) set
// last_was_local_var to mark the result register as a local's home slot,
// so free_expr_reg can leave it alone when an enclosing operator discards
// the value (`if ((v = expr))`, `while ((y = obj))`, `(n *= 0.3) > 0`).
// The pairing is a conjunction of last_was_local_var AND
// last_local_var_reg == reg; with the second half unset, free_expr_reg's
// guard under-protected and the local's home register was freed (when at
// the top of the register stack). The fix sets last_local_var_reg alongside
// last_was_local_var at both result sites, so the guard now triggers and
// the slot is preserved.
//
// WHAT MAKES THIS FRAGILE (read before simplifying anything below):
//
// Each case below is a statement that discards the assignment's result (a
// statement-condition or a comma tail). The very next statement re-reads
// the local. The patterns are also exercised by the existing
// `function_scope.js`, `test_capture_analysis.js`, and `test_spread.js`
// suites; this file pins the focused shapes the AGENTS.md comment
// enumerates so a future regression in the assignment result path is caught
// by a small test instead of the larger ones.
//
// The bug's observable consequences are narrow: free_reg only fires when
// the freed register sits at the top of the register stack (no temps
// allocated above it), and the freed slot only matters when a subsequent
// alloc reuses it AND the local is read directly via its register. The
// cases below are arranged to exercise those patterns.
//
"use strict";

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual) + ")");
}

// --- Simple `=` in a discarded position ----------------------------------
// if's condition discards the result; free_expr_reg sees the local's home
// register and must not free it. The very next read of `v` must see the
// assigned value, not a freed slot's stale content.
function simpleAssignInIf() {
  var v;
  if ((v = { tag: "alive" })) {
    return v.tag;
  }
  return "no-cond";
}
eq(simpleAssignInIf(), "alive",
   "if ((v = obj)) preserves v's home register across the discard");

// Same shape, while-true with assignment as condition.
function simpleAssignInWhile() {
  var n = 0;
  while ((n = n + 1) < 3) { }
  return n;
}
eq(simpleAssignInWhile(), 3,
   "while ((n = n + 1) < 3) keeps n's register through every iteration");

// Comma tail: the assignment's result is discarded by the comma operator's
// outer expression, so the slot has to survive.
function simpleAssignInComma() {
  var v;
  (0, (v = "kept"), 0);
  return v;
}
eq(simpleAssignInComma(), "kept",
   "comma tail (0, (v = ...), 0) preserves v's home register");

// --- Compound `op=` in a discarded position ------------------------------
// The same fix site lives in the compound branch, so compound assignments
// must hold up too.
function compoundInIf() {
  var v = 1;
  if ((v *= 10)) { return v; }
  return "no-cond";
}
eq(compoundInIf(), 10,
   "if ((v *= 10)) preserves v's home register");

// The example called out in the surrounding context: `(n *= 0.3) > 0`
// writes into n, then the `>` reads it. The > must see 0.3 (or 0, depending
// on n's prior value); the test forces a known n via the discarded form.
function compoundCompare() {
  var n = 1;
  var v = (n *= 0.3) > 0 ? n : -1;
  return v;
}
eq(compoundCompare(), 0.3,
   "(n *= 0.3) > 0 ? n : -1 reads n's register after the compound write");

// --- Free independence ---------------------------------------------------
// Two locals assigned in a discarded position must each keep their own
// slot; the last access reads the right one back.
function twoLocalsInComma() {
  var a, b;
  (0, (a = "A"), (b = "B"));
  return a + "|" + b;
}
eq(twoLocalsInComma(), "A|B",
   "two locals assigned in a discarded comma tail keep distinct registers");

// --- Object pattern: the destructuring assignment's result is also a local
// when the pattern is purely simple identifiers. The compiler routes this
// through the same simple-assignment result path.
function destructureInComma() {
  var p;
  (0, (({ x: p } = { x: "PX" })));
  return p;
}
eq(destructureInComma(), "PX",
   "destructuring assignment in a discarded comma tail preserves its target");

print('codegen_assignment_last_local_var_reg: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }