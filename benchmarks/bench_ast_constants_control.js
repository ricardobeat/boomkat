// Same arithmetic with parameter operands: literal folding is ineligible.
function kernel(x, a, b, c, d, e, f) {
    return x + ((a + b) * c - d / b) + ((e % c) * (f - a));
}
var total = 0;
for (var i = 0; i < 1000000; i++) total += kernel(i & 255, 2, 3, 4, 9, 11, 7);
if (total !== 159493856) throw new Error('control kernel: ' + total);
print(total);
