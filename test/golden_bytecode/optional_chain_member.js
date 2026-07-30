// Optional chaining embeds control flow INSIDE a member expression: the
// nullish short-circuit must skip the whole remaining chain, not just the
// next access, and the undefined result has to reach the same join register
// the non-nullish path writes.
// Behavioural pair: test/codegen_control_flow_expr.js
function optChain(o) {
  return o?.a?.b;
}
optChain(null);
