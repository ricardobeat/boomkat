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

// ── Both operands assign the SAME local ──────────────────────────────────
// Previously miscompiled: the left operand's VALUE was not copied to a temp,
// so the right operand's assignment overwrote w's home register before the
// MUL read it, and both MUL inputs decoded to w's slot:
//
//     [3] LDINT r0, +2      ; w = 2
//     [4] LDINT r0, +3      ; w = 3  -- clobbered the left operand
//     [5] MUL   r1 = r0, r0 ; 3 * 3 => 9
//
// `a op b` must use a's value as of before b runs (GetValue(lref) precedes
// b's evaluation), so this is 2 * 3 = 6. binary_expr now copies the left
// value to a temp ahead of the right operand whenever the right operand can
// write a register. Only misbehaved inside a function; at top level globals
// take a different path and were already correct.
function sameTargetBoth() {
  var w = 0;
  var r = (w = 2) * (w = 3);
  return r + ":" + w;
}
eq(sameTargetBoth(), "6:3", "(w=2)*(w=3) evaluates left before clobber");

// Addition is affected identically — the defect was never specific to `*`.
function sameTargetBothAdd() {
  var x = 0;
  var r = (x = 2) + (x = 3);
  return r + ":" + x;
}
eq(sameTargetBothAdd(), "5:3", "(x=2)+(x=3) evaluates left before clobber");

// The same variable assigned only on the right: the bare `v` read on the left
// must still see the pre-assignment value.
function sameTargetRightOnly() {
  var v = 10;
  var r = v - (v = 4);
  return r + ":" + v;
}
eq(sameTargetRightOnly(), "6:4", "v-(v=4) reads v before the assignment");

// Chained, so the temp for the first operator is still live across the second.
function sameTargetChained() {
  var w = 0;
  var r = (w = 2) * (w = 3) * (w = 4);
  return r + ":" + w;
}
eq(sameTargetChained(), "24:4", "(w=2)*(w=3)*(w=4) chains left-to-right");

// Inside a loop, where the register pressure and the back edge differ.
function sameTargetInLoop() {
  var out = 0, w = 0;
  for (var i = 0; i < 3; i++) { out += (w = 2) * (w = 3); }
  return out + ":" + w;
}
eq(sameTargetInLoop(), "18:3", "(w=2)*(w=3) inside a loop");

// A compound assignment on the right also writes the home register.
function sameTargetCompoundRight() {
  var n = 5;
  var r = n + (n *= 2);
  return r + ":" + n;
}
eq(sameTargetCompoundRight(), "15:10", "n+(n*=2) reads n before the compound");

// An update expression on the right likewise.
function sameTargetUpdateRight() {
  var n = 5;
  var r = n + (n++);
  return r + ":" + n;
}
eq(sameTargetUpdateRight(), "10:6", "n+(n++) reads n before the increment");

// ── Compound assignment reads its target BEFORE evaluating the RHS ───────
// `g op= rhs` is: resolve the Reference for g, GetValue(g) -> old, evaluate
// rhs, apply op(old, rhs), PutValue. Previously the RHS was compiled first
// and the compound op then read g's home register, which the RHS had already
// overwritten — `g += (g = 2)` computed 2 + 2 = 4 instead of 5 + 2 = 7.
function compoundRhsAssignsTargetAdd() {
  var g = 5;
  g += (g = 2);
  return g;
}
eq(compoundRhsAssignsTargetAdd(), 7, "g += (g=2) reads g before the RHS");

function compoundRhsAssignsTargetSub() {
  var g = 5;
  g -= (g = 2);
  return g;
}
eq(compoundRhsAssignsTargetSub(), 3, "g -= (g=2) reads g before the RHS");

function compoundRhsAssignsTargetMul() {
  var g = 5;
  g *= (g = 3);
  return g;
}
eq(compoundRhsAssignsTargetMul(), 15, "g *= (g=3) reads g before the RHS");

// A non-commutative operator, so an operand swap cannot hide behind the value.
function compoundRhsAssignsTargetShift() {
  var g = 8;
  g >>= (g = 2);
  return g;
}
eq(compoundRhsAssignsTargetShift(), 2, "g >>= (g=2) reads g before the RHS");

// The compound expression's own VALUE must also be the post-op result.
function compoundExprValue() {
  var g = 5;
  var r = (g += (g = 2));
  return r + ":" + g;
}
eq(compoundExprValue(), "7:7", "(g += (g=2)) evaluates to 7");

// String concatenation goes through the same ADD.
function compoundRhsAssignsTargetConcat() {
  var s = "a";
  s += (s = "b");
  return s;
}
eq(compoundRhsAssignsTargetConcat(), "ab", "s += (s='b') reads s before the RHS");

// Inside a loop, where the back edge and register pressure differ.
function compoundInLoop() {
  var g = 5, out = "";
  for (var i = 0; i < 2; i++) { g = 5; g += (g = 2); out += g + ","; }
  return out;
}
eq(compoundInLoop(), "7,7,", "g += (g=2) inside a loop");

// A RHS that assigns a DIFFERENT variable must not gain the copy's cost or
// change behaviour.
function compoundRhsAssignsOther() {
  var g = 5, z = 0;
  g += (z = 2);
  return g + ":" + z;
}
eq(compoundRhsAssignsOther(), "7:2", "g += (z=2) unaffected");

// Member targets take the PUTPROP path and were already correct; pin them so
// the local-only gating cannot silently start applying to them.
function compoundObjPropRhsAssigns() {
  var o = { p: 5 };
  o.p += (o.p = 2);
  return o.p;
}
eq(compoundObjPropRhsAssigns(), 7, "o.p += (o.p=2) reads o.p before the RHS");

function compoundArrIdxRhsAssigns() {
  var q = [5];
  q[0] += (q[0] = 2);
  return q[0];
}
eq(compoundArrIdxRhsAssigns(), 7, "q[0] += (q[0]=2) reads q[0] before the RHS");

// ── Logical assignment must still SHORT-CIRCUIT ──────────────────────────
// &&=, ||= and ??= do not evaluate the RHS when the test fails, so they must
// not acquire the eager old-value copy.
function logicalAndAssignSkips() {
  var g = 0, ran = 0;
  g &&= (ran = 1);
  return g + ":" + ran;
}
eq(logicalAndAssignSkips(), "0:0", "g &&= rhs skips the RHS when g is falsy");

function logicalOrAssignSkips() {
  var g = 1, ran = 0;
  g ||= (ran = 1);
  return g + ":" + ran;
}
eq(logicalOrAssignSkips(), "1:0", "g ||= rhs skips the RHS when g is truthy");

function nullishAssignSkips() {
  var g = 0, ran = 0;
  g ??= (ran = 1);
  return g + ":" + ran;
}
eq(nullishAssignSkips(), "0:0", "g ??= rhs skips the RHS when g is not nullish");

// …and must still take the RHS when the test passes, including when the RHS
// assigns the target itself (the assignment wins, then PutValue rewrites it).
function logicalAndAssignTakes() {
  var g = 1;
  g &&= (g = 9);
  return g;
}
eq(logicalAndAssignTakes(), 9, "g &&= (g=9) takes the RHS when g is truthy");

function nullishAssignTakes() {
  var g = null;
  g ??= (g = 9);
  return g;
}
eq(nullishAssignTakes(), 9, "g ??= (g=9) takes the RHS when g is null");

print('codegen_assign_clobber: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
