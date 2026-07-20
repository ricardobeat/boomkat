// Negative case: immediate exceeds signed-8-bit range (-128..127), so the
// SUBI fusion must NOT fire. Proves the i8 guard in the ADDI/SUBI pass.
function offset(x) {
  return x - 256;
}
offset(1000);
