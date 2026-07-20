// SUBI fusion: LDINT rK, imm + SUB rD = rX, rK -> ADDI/SUBI, twice (n-1, n-2).
function fib(n) {
  if (n <= 1) return n;
  return fib(n - 1) + fib(n - 2);
}
fib(10);
