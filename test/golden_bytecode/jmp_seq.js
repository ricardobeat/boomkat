// Strict-equality branch fusion: === in an if condition → JMP_SNEQ
function f(n) { if (n === 0) return "zero"; return "other"; }
print(f(0), f(1));
