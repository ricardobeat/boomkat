// A literal right operand folds into the compare-and-branch immediate forms.
function f(n) { if (n < 2) return n; return n > 100 ? 100 : n === 50 ? 0 : n; }
function g(n) { var i = 0; while (i !== 10) { i = i + n; } return i; }
print(f(1), f(60), g(5));
