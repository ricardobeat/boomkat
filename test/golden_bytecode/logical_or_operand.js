// `||` in operand position — the inverted-polarity twin of
// logical_and_operand: the short-circuit branch fires on TRUTHY, so the
// IF_TRUE/IF_FALSE choice and the join direction are both pinned here.
// Behavioural pair: test/codegen_control_flow_expr.js
function orOperand(a, b) {
  return 1 + (a || b);
}
orOperand(false, 5);
