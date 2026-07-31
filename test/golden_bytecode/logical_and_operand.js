// `&&` in OPERAND position: same branch-and-join machinery as a ternary, but
// the join register is the left operand's own slot. 4f486724's defective
// guard was an "&&-bridge correction" matching on opcode alone, so this shape
// is where a bridge rewrite that ignores register identity first shows up.
// Behavioural pair: test/codegen_control_flow_expr.js
function andOperand(a, b) {
  return 1 + (a && b);
}
andOperand(true, 5);
