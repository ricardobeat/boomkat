// Conditional whose ARMS are themselves binary expressions: each arm ends in
// an ADD/MUL that must write the shared result register before the join, and
// the ADDI/SUBI peepholes run over instructions that are branch targets.
// Behavioural pair: test/codegen_control_flow_expr.js
function pick(t, a, b) {
  return t ? a + 1 : b * 2;
}
pick(true, 4, 5);
