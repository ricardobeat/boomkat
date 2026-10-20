// Benchmark: IC on prototype property access
// Accessing inherited properties requires walking the prototype chain.
// The IC should skip the chain walk on repeated accesses.
function Base() {}
Base.prototype.x = 1;
Base.prototype.y = 2;
Base.prototype.z = 3;
Base.prototype.w = 4;

function bench() {
    var obj = new Base();
    var sum = 0;
    for (var i = 0; i < 5000000; i++) {
        sum += obj.x + obj.y + obj.z + obj.w;
    }
    return sum;
}

var r = bench();
if (r !== 50000000) {
    print("FAIL: " + r);
} else {
    print("PASS: " + r);
}
