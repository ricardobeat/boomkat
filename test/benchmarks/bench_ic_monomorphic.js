// Benchmark: IC effectiveness on monomorphic property access
// Tests the shape+IC fast path: repeatedly accessing .x on objects
// created the same way (same shape).
function Point(x, y) {
    this.x = x;
    this.y = y;
    this.label = "p";
}

function bench() {
    var sum = 0;
    var p = new Point(1, 2);
    // Warm up: access .x many times on the same object (monomorphic IC)
    for (var i = 0; i < 10000000; i++) {
        sum += p.x;
    }
    return sum;
}

var result = bench();
if (result !== 10000000) {
    print("FAIL: expected 10000000 got " + result);
} else {
    print("PASS: " + result);
}
