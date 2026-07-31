// Behavioural pair for the control-flow-carrying-expression goldens in
// test/golden_bytecode/ (ternary_*, logical_*, optional_chain_member).
//
// The goldens pin the INSTRUCTION SHAPE; this file pins the ANSWER. Both are
// needed: a golden regenerated with `just update-golden-bytecode` after a real
// regression silently enshrines the broken codegen as expected. That is not
// hypothetical — before 073aa16b, `5 + (t ? 10 : 20)` returned 25, and a
// golden regenerated at that commit would have made the wrong bytecode the
// contract. These assertions would have failed instead.
//
// Regression covered: 073aa16b — a conditional expression in operand position
// had its join (the move of the false arm's result into the shared result
// register) rewritten by two peepholes that did not check whether the
// instruction they were folding into was a branch target.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// ── Conditional expression in operand position ───────────────────────────
// The exact 073aa16b repro: ternary as the RIGHT operand. t===true must take
// the TRUE arm (10), so 5+10 === 15. The bug returned 25 (false arm).
function addTernary(t) { return 5 + (t ? 10 : 20); }
eq(addTernary(true), 15, "ternary as right operand, true arm");
eq(addTernary(false), 25, "ternary as right operand, false arm");

// Mirror: ternary as the LEFT operand.
function ternaryPlus(t) { return (t ? 10 : 20) + 5; }
eq(ternaryPlus(true), 15, "ternary as left operand, true arm");
eq(ternaryPlus(false), 25, "ternary as left operand, false arm");

// Both operands are conditionals — two independent branch/join pairs.
function bothTernary(a, b) { return (a ? 1 : 2) + (b ? 10 : 20); }
eq(bothTernary(true, true), 11, "both operands ternary, true/true");
eq(bothTernary(true, false), 21, "both operands ternary, true/false");
eq(bothTernary(false, true), 12, "both operands ternary, false/true");
eq(bothTernary(false, false), 22, "both operands ternary, false/false");

// Nested / chained conditionals: the outer jump must clear the whole inner
// region, not land inside it.
function grade(n) { return n > 90 ? 1 : n > 80 ? 2 : 3; }
eq(grade(95), 1, "nested ternary, outer true arm");
eq(grade(85), 2, "nested ternary, inner true arm");
eq(grade(50), 3, "nested ternary, inner false arm");

// Conditional on the right of a compound assignment: read, branch, join and
// write-back all touch the same slot.
function addCond(t) { var x = 7; x += t ? 10 : 20; return x; }
eq(addCond(true), 17, "compound assign with ternary rhs, true arm");
eq(addCond(false), 27, "compound assign with ternary rhs, false arm");

// Conditional whose arms are themselves binary expressions.
function pick(t, a, b) { return t ? a + 1 : b * 2; }
eq(pick(true, 4, 5), 5, "ternary with binary arms, true arm");
eq(pick(false, 4, 5), 10, "ternary with binary arms, false arm");

// Ternary directly inside a call argument and an array literal — the join
// register is consumed by something other than a binary op.
function id(x) { return x; }
eq(id(true ? 3 : 4), 3, "ternary as call argument");
eq([true ? 3 : 4, false ? 3 : 4][0], 3, "ternary in array literal, true arm");
eq([true ? 3 : 4, false ? 3 : 4][1], 4, "ternary in array literal, false arm");

// ── Short-circuit operators in operand position ──────────────────────────
// Same branch-and-join machinery as a ternary, but the join register is the
// left operand's own slot.
function andOperand(a, b) { return 1 + (a && b); }
eq(andOperand(true, 5), 6, "&& in operand position, right value taken");
eq(andOperand(false, 5), 1, "&& in operand position, short-circuits to false");

function orOperand(a, b) { return 1 + (a || b); }
eq(orOperand(false, 5), 6, "|| in operand position, right value taken");
eq(orOperand(2, 5), 3, "|| in operand position, short-circuits to left");

function nullishOperand(a, b) { return 1 + (a ?? b); }
eq(nullishOperand(null, 5), 6, "?? in operand position, null takes right");
eq(nullishOperand(undefined, 5), 6, "?? in operand position, undefined takes right");
eq(nullishOperand(0, 5), 1, "?? in operand position, 0 is NOT nullish");

// ?? must not treat falsy-but-defined values as nullish, unlike ||.
eq(0 ?? 7, 0, "?? keeps 0");
eq(0 || 7, 7, "|| replaces 0");
eq("" ?? "x", "", "?? keeps empty string");

// Mixed chain: three short-circuit exits sharing one join.
function mixedChain(a, b, c) { return (a && b) || c; }
eq(mixedChain(true, 0, 9), 9, "mixed && / || chain, falls through to c");
eq(mixedChain(true, 5, 9), 5, "mixed && / || chain, takes b");
eq(mixedChain(false, 5, 9), 9, "mixed && / || chain, a short-circuits");

// Short-circuit must not EVALUATE the skipped side.
var sideEffects = 0;
function bump() { sideEffects++; return 1; }
sideEffects = 0;
false && bump();
eq(sideEffects, 0, "&& does not evaluate rhs when short-circuiting");
sideEffects = 0;
true || bump();
eq(sideEffects, 0, "|| does not evaluate rhs when short-circuiting");
sideEffects = 0;
1 ?? bump();
eq(sideEffects, 0, "?? does not evaluate rhs when lhs is non-nullish");
sideEffects = 0;
true ? 1 : bump();
eq(sideEffects, 0, "ternary does not evaluate the untaken arm");

// ── Optional chaining: control flow inside a member expression ───────────
function optChain(o) { return o?.a?.b; }
eq(optChain(null), undefined, "optional chain short-circuits on null");
eq(optChain(undefined), undefined, "optional chain short-circuits on undefined");
eq(optChain({}), undefined, "optional chain stops at missing intermediate");
eq(optChain({ a: { b: 42 } }), 42, "optional chain full traversal");

// The short-circuit must skip the ENTIRE remaining chain, not just one link.
var deepCalls = 0;
function tracker() { deepCalls++; return { b: 1 }; }
deepCalls = 0;
var nothing = null;
eq(nothing?.a[tracker()], undefined, "optional chain skips rest of chain");
eq(deepCalls, 0, "optional chain does not evaluate skipped subscript");

// Optional chaining in operand position, so the join feeds a binary op.
function optSum(o) { return 1 + (o?.a ?? 10); }
eq(optSum(null), 11, "optional chain in operand position, short-circuit");
eq(optSum({ a: 5 }), 6, "optional chain in operand position, value");

print('codegen_control_flow_expr: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
