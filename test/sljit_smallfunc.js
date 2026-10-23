// Small functions invoked few times, each invocation driving a long loop that
// the function tier can cover only if taken backedges warm it.
function accumulate(o, n) {
    var x = 0.25;
    var y = 1.5;
    for (var i = 0; i < n; i++) {
        x = x + o.x;
        y = y + o.y;
        if (i & 1) x = x + y * 0.125;
        else y = y + x * 0.25;
    }
    return x + y;
}
var o = { x: 0.5, y: 1.25 };
var expected = accumulate(o, 64);
for (var call = 0; call < 8; call++) {
    if (accumulate(o, 64) !== expected) throw new Error("warm mismatch");
}
var start = Date.now();
var result = accumulate(o, 4000000);
print("smallfunc: " + (Date.now() - start) + " ms result=" + result);
