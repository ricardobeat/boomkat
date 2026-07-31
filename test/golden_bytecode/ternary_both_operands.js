// Both operands are conditional expressions: two independent branch/join
// pairs feeding one ADD. Pins that the second ternary's jump offsets are
// computed from its own start, not from the enclosing expression, and that
// the first ternary's result register survives the second one's branches.
// Behavioural pair: test/codegen_control_flow_expr.js
function bothTernary(a, b) {
  return (a ? 1 : 2) + (b ? 10 : 20);
}
bothTernary(true, false);
