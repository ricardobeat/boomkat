// Strict-equality branch fusion: === in an if condition → JMP_SNEQ
function f(n, m) { if (n === m) return "same"; return "other"; }
print(f(0, 0), f(1, 0));
