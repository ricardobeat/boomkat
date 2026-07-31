// The 4f486724 shape under a LABEL with a labeled continue: the continue is a
// second jump into the same back-edge region, so an offset remap that is
// correct for the loop's own back-edge can still corrupt the labeled one.
// Behavioural pair: test/codegen_loop_backedge.js
function labeledLoop(n) {
  var s = "";
  outer:
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (j) { continue outer; }
      s += "b";
    }
  }
  return s;
}
labeledLoop(3);
