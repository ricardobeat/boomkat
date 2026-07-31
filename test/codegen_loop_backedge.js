// Behavioural pair for the loop back-edge goldens in test/golden_bytecode/
// (loop_backedge_flat, loop_backedge_nested, loop_backedge_labeled).
//
// The goldens pin the negative jump offset; this file pins the ANSWER, so a
// regenerated golden cannot silently make a broken back-edge the contract.
//
// Regression covered: 4f486724 — the &&/|| bridge correction in the peephole
// pass matched on OPCODE ALONE and never checked register identity, so it
// fired on a loop body's unrelated `if (j)` and moved the loop's back-edge to
// land MID-BODY. The loop then re-entered *after* the truthiness test, so
// every iteration took the same arm.
//
// The trigger shape is specific: a bare truthiness test on the loop counter as
// the FIRST statement of the body. `if (j < 1)` or a test on a different
// variable does not reproduce it — the defective guard keyed on the shape of a
// bare `IF_FALSE <reg>` immediately at the branch target.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// ── Flat loop: the exact 4f486724 shape ──────────────────────────────────
// j is 0 on the first iteration only, so exactly the first pass takes the
// else arm: "b" then "a" for each remaining iteration. The bug produced all
// "b" (back-edge landed past the test, counter read as falsy every time).
function flatLoop(n) {
  var s = "";
  for (var j = 0; j < n; j++) {
    if (j) { s += "a"; } else { s += "b"; }
  }
  return s;
}
eq(flatLoop(1), "b", "flat loop back-edge, single iteration");
eq(flatLoop(2), "ba", "flat loop back-edge, two iterations");
eq(flatLoop(4), "baaa", "flat loop back-edge, four iterations");

// Same shape accumulating a number rather than a string, so the failure mode
// is not masked by string coercion anywhere.
function flatSum(n) {
  var t = 0;
  for (var j = 0; j < n; j++) {
    if (j) { t += 10; } else { t += 1; }
  }
  return t;
}
eq(flatSum(1), 1, "flat loop numeric, single iteration");
eq(flatSum(4), 31, "flat loop numeric, four iterations");

// ── Nested loops: two back-edges in flight ───────────────────────────────
// The inner counter resets each outer pass, so each outer iteration
// contributes exactly one "b" followed by (n-1) "a".
function nestedLoop(n) {
  var s = "";
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (j) { s += "a"; } else { s += "b"; }
    }
  }
  return s;
}
eq(nestedLoop(2), "baba", "nested loop back-edge, 2x2");
eq(nestedLoop(3), "baabaabaa", "nested loop back-edge, 3x3");

// The OUTER counter carrying the truthiness test, with the inner loop below
// it — exercises the other back-edge.
function nestedOuterTest(n) {
  var s = "";
  for (var i = 0; i < n; i++) {
    if (i) { s += "A"; } else { s += "B"; }
    for (var j = 0; j < 2; j++) { s += "."; }
  }
  return s;
}
eq(nestedOuterTest(3), "B..A..A..", "nested loop, outer counter test");

// ── Labeled loop and labeled continue ────────────────────────────────────
// `continue outer` is a second jump into the same back-edge region.
function labeledLoop(n) {
  var s = "";
  outer:
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (j) { continue outer; }
      s += "b";
    }
  }
  return s;
}
eq(labeledLoop(3), "bbb", "labeled continue back-edge");

// Labeled break out of the inner loop.
function labeledBreak(n) {
  var s = "";
  outer:
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (j) { break outer; }
      s += "b";
    }
  }
  return s;
}
eq(labeledBreak(3), "b", "labeled break back-edge");

// ── while / do-while carry their own back-edge lowering ──────────────────
function whileLoop(n) {
  var s = "", j = 0;
  while (j < n) {
    if (j) { s += "a"; } else { s += "b"; }
    j++;
  }
  return s;
}
eq(whileLoop(4), "baaa", "while loop back-edge");

function doWhileLoop(n) {
  var s = "", j = 0;
  do {
    if (j) { s += "a"; } else { s += "b"; }
    j++;
  } while (j < n);
  return s;
}
eq(doWhileLoop(4), "baaa", "do-while loop back-edge");

// The counter test guarding a `continue` as the body's first statement —
// the body's entry instruction is then a branch with no arm below it.
function continueFirst(n) {
  var s = "";
  for (var j = 0; j < n; j++) {
    if (j) { continue; }
    s += "b";
  }
  return s;
}
eq(continueFirst(4), "b", "continue as first body statement");

print('codegen_loop_backedge: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
