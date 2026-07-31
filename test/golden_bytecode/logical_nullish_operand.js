// `??` in operand position. Unlike && / ||, the test is nullish-ness rather
// than truthiness, so it cannot reuse the boolean branch fusions — pins that
// the nullish path still emits a correctly-targeted branch and join.
// Behavioural pair: test/codegen_control_flow_expr.js
function nullishOperand(a, b) {
  return 1 + (a ?? b);
}
nullishOperand(null, 5);
