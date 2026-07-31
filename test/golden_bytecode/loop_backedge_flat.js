// Regression 4f486724: a bare truthiness test on the counter as the FIRST
// statement of a loop body. The &&/|| bridge correction matched on opcode
// alone and never checked register identity, so it fired on this unrelated
// `if (j)` and moved the loop's back-edge to land MID-BODY — the loop then
// re-entered after the test and every iteration took the else arm ("bbbb"
// instead of "baaa"). Pins that JMP_LT's negative offset targets the body's
// first instruction (the IF_FALSE), not the arm below it.
// Behavioural pair: test/codegen_loop_backedge.js
function flatLoop(n) {
  var s = "";
  for (var j = 0; j < n; j++) {
    if (j) { s += "a"; } else { s += "b"; }
  }
  return s;
}
flatLoop(4);
