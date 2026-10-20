// Reused-input matrix multiplication with one fresh six-element result per call.
function mul(a, b) {
    return [
        a[0] * b[0] + a[2] * b[1], a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3], a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4], a[1] * b[4] + a[3] * b[5] + a[5]
    ];
}

var a = [1, 0, 0, 1, 7, 11];
var b = [1, 0, 0, 1, 3, 5];
var checksum = 0;
var start = Date.now();
for (var i = 0; i < 1000000; i++) {
    var result = mul(a, b);
    checksum += result[0] + result[1] + result[2] + result[3] + result[4] + result[5];
}
print("mul_probe: calls=1000000 total=" + (Date.now() - start)
      + "ms checksum=" + checksum);
