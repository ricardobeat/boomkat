// Regression 073aa16b: a conditional expression as the RIGHT operand of a
// binary op. Two jump-blind peepholes rewrote the ternary's join (the LDREG
// that moves the false arm's result into the true arm's register) as if it
// were straight-line code, so `5 + (t ? 10 : 20)` returned 25 for t === true.
// Pins: IF_FALSE skips to the false arm, the true arm's JUMP clears both the
// false arm AND its join, and the join LDREG survives as a separate insn.
// Behavioural pair: test/codegen_control_flow_expr.js
function addTernary(t) {
  return 5 + (t ? 10 : 20);
}
addTernary(true);
