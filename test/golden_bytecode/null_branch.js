// Loose equality against null/undefined fuses with its branch: JMP_NULL/JMP_NNULL.
// Other loose compares fuse to JMP_EQ/JMP_NEQ, and `!x` feeding a branch inverts it.
function f(a, b) {
  if (a == null) return 1;
  if (b != a) return 2;
  if (!b) return 3;
  return 4;
}
print(f(null, 1), f(1, 2), f(1, 0), f(1, 1));
