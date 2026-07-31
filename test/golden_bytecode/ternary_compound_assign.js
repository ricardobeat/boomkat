// Conditional expression on the right of a COMPOUND assignment. The read of
// the target, the branch/join, and the write-back all touch the same slot, so
// a join rewritten across the branch silently reads the pre-increment value.
// Behavioural pair: test/codegen_control_flow_expr.js
function addCond(t) {
  var x = 7;
  x += t ? 10 : 20;
  return x;
}
addCond(true);
