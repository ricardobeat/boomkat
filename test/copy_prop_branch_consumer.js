// A copy `x = t` feeding a compare-branch must survive when the taken path
// skips the loop body's later write to x and x is read after the loop.
function lowerBound(h, lo, hi, p) {
    var x = 0;
    var i = lo;
    do {
        x = h[i];
        if (x < p) {
            i = i + 1;
            x = h[i];
            if (x < p) {
                i = i + 1;
                continue;
            }
        }
        break;
    } while (i < hi);
    return x * 100 + i;
}
var h = [1, 2, 3, 9, 10];
var cases = [
    [0, 4, 5, 903],
    [0, 4, 3, 302],
    [0, 4, 1, 100],
    [3, 4, 5, 903],
];
for (var k = 0; k < cases.length; k++) {
    var c = cases[k];
    var got = lowerBound(h, c[0], c[1], c[2]);
    if (got !== c[3]) throw new Error("case " + k + ": got " + got + ", want " + c[3]);
}
