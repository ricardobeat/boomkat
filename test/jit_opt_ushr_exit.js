// An unsigned shift whose result does not fit an int32 exits the optimized code, and the baseline
// runs the shift again from the operands in the frame. The shift count dies at the shift, so it
// may share a register with the result: the exit must still store the count, not the result.
var rec = new Int32Array(64);
function shifts(n) {
    var h = 0;
    for (var i = 0; i < n; i++) {
        var a = i & 63;
        var v = (-1 >>> (a & 31)) & 0xffff;
        rec[i] = v;
        h = (Math.imul(h, 31) + v) | 0;
    }
    return h;
}
for (var round = 0; round < 2000; round++) {
    shifts(64);
    for (var i = 0; i < 64; i++) {
        var want = (-1 >>> (i & 31)) & 0xffff;
        if (rec[i] !== want) {
            print("FAIL round " + round + " a=" + i + ": " + rec[i] + " !== " + want);
            throw new Error("FAIL");
        }
    }
}
