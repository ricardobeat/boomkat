// Assignment as an arithmetic operand: `(v=5)+1` must copy v's home register
// to a temp before the ADD, so the ADD does not overwrite v. Part of the
// b0fdc49c (assignment register clobber) family — assignment_expr returned
// the target local's home register without setting last_was_local_var, so
// binary_expr's copy-to-temp guard never fired.
//
// The sibling shape `(w=2)*(w=3)`, where BOTH operands assign the same local,
// is deliberately NOT pinned here: it is still miscompiled (see the
// known-failure section of test/codegen_assign_clobber.js). Pinning its
// current disasm would enshrine the wrong answer as expected.
// Behavioural pair: test/codegen_assign_clobber.js
function assignArith() {
  var v = 0;
  var a = (v = 5) + 1;
  return a + ":" + v;
}
assignArith();
