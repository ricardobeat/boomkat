function kernel(a, b = a + 1) { return b; }
var total = 0;
for (var i = 0; i < 200000; i++) total += kernel(i, i + 1);
if (total !== 20000100000) throw new Error('sum: ' + total);
print(total);
