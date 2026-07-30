// Direct regression coverage for the assignment register-clobber bug fixed in
// b0fdc49c (commit 907921a5, bug 2).
//
// assignment_expr returned the target local's HOME register as the value of
// the assignment expression, but never set last_was_local_var. binary_expr's
// copy-to-temp guard reads exactly that flag, so it never fired and the
// enclosing operator used the variable's own slot as its destination:
// `(u = 45) > 0` emitted `GT r0 = r0, r2` straight into u, leaving u === true
// instead of 45.
//
// Before this file the only coverage was incidental behaviour of the
// third-party minified bundle in test/modules/t11_colord. That bundle could be
// updated at any time, silently removing the coverage, and a failure reported
// as "colord broke" rather than naming the defect.
//
// All expectations below were checked against node.
//
// Golden pair: test/golden_bytecode/assign_in_comparison.js, assign_in_arith.js

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// ── The exact reported repro ─────────────────────────────────────────────
// The comparison must NOT be emitted into u's slot. Pre-fix: u === true.
function assignCompare() {
  var u = 0;
  var r = (u = 45) > 0;
  return u + ":" + r;
}
eq(assignCompare(), "45:true", "(u=45)>0 leaves u intact");

// Same, with the comparison inverted and with the assignment on the right.
function assignCompareRight() {
  var u = 0;
  var r = 0 < (u = 45);
  return u + ":" + r;
}
eq(assignCompareRight(), "45:true", "0<(u=45) leaves u intact");

// ── Assignment as an arithmetic operand ──────────────────────────────────
function assignArith() {
  var v = 0;
  var a = (v = 5) + 1;
  return a + ":" + v;
}
eq(assignArith(), "6:5", "(v=5)+1 leaves v intact");

function assignArithSub() {
  var v = 0;
  var a = (v = 5) - 2;
  return a + ":" + v;
}
eq(assignArithSub(), "3:5", "(v=5)-2 leaves v intact");

// ── Two assignments in one expression ────────────────────────────────────
// Distinct targets: each keeps its own value, and the sum is correct.
function twoAssigns() {
  var a = 0, b = 0;
  var s = (a = 1) + (b = 2);
  return s + ":" + a + ":" + b;
}
eq(twoAssigns(), "3:1:2", "((a=1)+(b=2)) leaves both intact");

// Nested in a further binary expression.
function nestedAssigns() {
  var a = 0, b = 0;
  var s = ((a = 1) + (b = 2)) * 10;
  return s + ":" + a + ":" + b;
}
eq(nestedAssigns(), "30:1:2", "((a=1)+(b=2))*10 leaves both intact");

// ── Compound assignment as an operand ────────────────────────────────────
// The compound path hands back the home register too (`(n *= 0.3) > 0`).
function compoundAssign() {
  var n = 10;
  n *= 0.3;
  return n;
}
eq(compoundAssign(), 3, "compound assign result");

function compoundInComparison() {
  var n = 10;
  var r = (n *= 2) > 5;
  return n + ":" + r;
}
eq(compoundInComparison(), "20:true", "(n*=2)>5 leaves n intact");

function compoundInArith() {
  var n = 10;
  var a = (n += 5) + 1;
  return a + ":" + n;
}
eq(compoundInArith(), "16:15", "(n+=5)+1 leaves n intact");

// ── Non-local targets take a different path and must also be correct ─────
function objPropTarget() {
  var o = { p: 0 };
  var r = (o.p = 45) > 0;
  return o.p + ":" + r;
}
eq(objPropTarget(), "45:true", "(o.p=45)>0 leaves o.p intact");

function arrIndexTarget() {
  var arr = [0];
  var r = (arr[0] = 45) > 0;
  return arr[0] + ":" + r;
}
eq(arrIndexTarget(), "45:true", "(arr[0]=45)>0 leaves arr[0] intact");

function objPropArith() {
  var o = { p: 0 };
  var a = (o.p = 5) + 1;
  return a + ":" + o.p;
}
eq(objPropArith(), "6:5", "(o.p=5)+1 leaves o.p intact");

// Assignment feeding a call argument and a logical operator, where the
// consumer is not a plain binary operator.
function assignInCall() {
  var u = 0;
  function take(x) { return x; }
  var r = take(u = 45);
  return u + ":" + r;
}
eq(assignInCall(), "45:45", "assignment as call argument leaves target intact");

function assignInLogical() {
  var u = 0;
  var r = (u = 45) && true;
  return u + ":" + r;
}
eq(assignInLogical(), "45:true", "assignment under && leaves target intact");

// ── KNOWN FAILURE (not asserted): both operands assign the SAME local ────
// `(w = 2) * (w = 3)` is still miscompiled: the left operand is not copied to
// a temp, so the right operand's assignment overwrites w's home register
// before the MUL reads it, and both MUL inputs decode to w's slot:
//
//     [3] LDINT r0, +2      ; w = 2
//     [4] LDINT r0, +3      ; w = 3  -- clobbers the left operand
//     [5] MUL   r1 = r0, r0 ; 3 * 3 => 9
//
// node (and the spec) give 6; this engine gives 9. The b0fdc49c fix improved
// this shape (w itself now reads back as 3 rather than 9) but did not fix the
// product. Deliberately left as a live defect rather than asserted at 9 — a
// test pinning the wrong answer is worse than no test. Note it only misbehaves
// inside a function; at top level globals take a different path and give 6.
//
//     function g(){ var w=0; return (w=2)*(w=3); }  // returns 9, should be 6
//
// When that is fixed, replace this comment with:
//     eq(sameTargetBoth(), "6:3", "(w=2)*(w=3) evaluates left before clobber");

print('codegen_assign_clobber: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
