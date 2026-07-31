// Chained/nested conditionals: the false arm is itself a conditional, so the
// inner branch targets sit inside the outer one's false-arm span. Pins that
// the outer JUMP clears the whole nested region rather than landing inside it.
// Behavioural pair: test/codegen_control_flow_expr.js
function grade(n) {
  return n > 90 ? 1 : n > 80 ? 2 : 3;
}
grade(85);
