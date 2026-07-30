// Mixed && / || chain in operand position: three short-circuit exits share
// one join register. Pins that each exit branch targets the SAME join and
// that the chain's jump offsets survive any peephole compaction/remap.
// Behavioural pair: test/codegen_control_flow_expr.js
function mixedChain(a, b, c) {
  return (a && b) || c;
}
mixedChain(true, 0, 9);
