// JMP_LT_G fusion: GETGLOBAL_PRIM rX, S + JMP_LT off, rB, rX -> a two-word
// JMP_LT_G whose trailing NOP carries the global's name index. The loop bound
// is read straight into the compare instead of going through a scratch
// register.
//
// The bounds are globals that only ever hold numbers and the program has no
// eval/globalThis/Function/with, so the prim-slot proof classifies them as
// primitive-only and both halves of each pair are emitted in the fusable form.
//
// Nested loops are the shape that matters. JMP_LT_G keeps the original
// JMP_LT's offset verbatim, which is only correct because the fused op
// branches relative to i+2 after consuming both words while the unfused
// JMP_LT at i+1 branched relative to (i+1)+1. A flat loop cannot tell a
// correct carry-over from an off-by-one that happens to cancel, so the golden
// pins an inner and an outer back-edge whose distances differ.
//
// Behavioural pair: test/codegen_jmp_lt_g.js
var n = 4;
var m = 3;
var i = 0;
var j = 0;
var s = 0;

while (i < n) {
  j = 0;
  while (j < m) {
    s = s + 1;
    j = j + 1;
  }
  i = i + 1;
}
print(s, i, j);
