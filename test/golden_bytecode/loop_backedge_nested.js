// The 4f486724 shape with an INNER loop: two back-edges in flight, so a
// bridge correction that picks the wrong one is invisible in the flat case.
// Pins both negative jump offsets independently.
// Behavioural pair: test/codegen_loop_backedge.js
function nestedLoop(n) {
  var s = "";
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (j) { s += "a"; } else { s += "b"; }
    }
  }
  return s;
}
nestedLoop(2);
