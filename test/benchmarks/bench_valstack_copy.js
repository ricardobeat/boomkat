// Micro-benchmark: TVal copy throughput
// Measures value stack copy cost by exercising function calls with many args/locals

function copyTest(n, a, b, c, d) {
    var x1 = a;
    var x2 = b;
    var x3 = c;
    var x4 = d;
    var x5 = x1 + x2;
    var x6 = x3 + x4;
    var x7 = x5 + x6;
    if (n <= 0) return x7;
    return copyTest(n - 1, x7, x1, x2, x3) + copyTest(n - 2, x4, x5, x6, x7);
}

var N = 22;
var result = 0;
for (var rep = 0; rep < 11; rep++) {
    result = copyTest(N, 1, 2, 3, 4);
}
print(result);
