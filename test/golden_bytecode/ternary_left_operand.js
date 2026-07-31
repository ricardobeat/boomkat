// Conditional expression as the LEFT operand of a binary op — the mirror of
// ternary_right_operand. Here the join feeds the accumulator rather than the
// second ADD input, so a jump-blind rewrite corrupts a different register.
// Behavioural pair: test/codegen_control_flow_expr.js
function ternaryPlus(t) {
  return (t ? 10 : 20) + 5;
}
ternaryPlus(true);
