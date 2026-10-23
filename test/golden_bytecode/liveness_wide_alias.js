// Liveness scan must not read a WIDE branch offset's low byte as a register.
//
// JUMP/BREAK/CONTINUE pack a 24-bit signed offset across A/B/C, so field A is
// the offset's LOW BYTE, not a destination register. fusion_reg_live_from used
// to treat `jns.a == reg` as an overwrite for every format, so a `JUMP +2`
// ended the liveness scan for register 2 and reported it dead — permitting a
// fusion whose scratch value is still read later.
//
// This is the minimised form of
//   test262/test/language/expressions/object/
//     cpn-obj-lit-computed-property-name-from-condition-expression-true.js
// which is one of the 17 files whose fused bytecode changed when the guard was
// added. The ternary computed key emits the JUMP; the member call that reads
// the property back re-reads the same scratch register.
//
// The LDCONST feeding each property read now folds into a GETPROPC: its only
// later mention was the argument count of `CALL r3 = r3, 2`, which the
// liveness scan used to read as register 2, and that false read is what kept
// it. The JUMP guard stays in fusion_reg_live_from; this golden records the
// output with both corrections.
let o = {
  [true ? 1 : 2]: 2
};
assertish.same(
  o[true ? 1 : 2],
  2
);
assertish.same(
  o[String(true ? 1 : 2)],
  2
);
