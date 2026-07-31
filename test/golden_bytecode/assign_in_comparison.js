// Regression b0fdc49c (assignment register clobber): assignment_expr returned
// the target local's home register without setting last_was_local_var, so
// binary_expr's copy-to-temp guard never fired and the comparison was emitted
// INTO u's own slot — leaving u === true instead of 45. Pins that the GT
// destination register is NOT u's home register.
// Behavioural pair: test/codegen_assign_clobber.js
function assignCompare() {
  var u = 0;
  var r = (u = 45) > 0;
  return u + ":" + r;
}
assignCompare();
