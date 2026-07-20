// ADDI fusion: LDINT rK, imm + ADD rD = rX, rK -> ADDI, for `i = i + 1`.
function sumLoop(n) {
  var total = 0;
  for (var i = 0; i < n; i = i + 1) {
    total = total + i;
  }
  return total;
}
sumLoop(5);
