// The backedge must emit the integer-to-double conversion for x.
function latchFloat(a, n) {
    var x = 1;
    for (var i = 0; i < n; i++) { x = x + 0.25; a[i] = x; x = i; }
    return x;
}
for (var warm = 0; warm < 200; warm++) {
    var a = new Float64Array(64);
    if (latchFloat(a, 64) !== 63) throw Error('latch result');
    for (var i = 1; i < 64; i++) if(a[i] !== i-1+0.25) throw Error('latch element '+i+': '+a[i]);
}
print('latch float PASS');
