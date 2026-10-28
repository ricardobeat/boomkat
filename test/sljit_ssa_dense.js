// A guarded numeric dense load may stay live across a store. A later non-number
// must recover before coercion or overwriting the only array reference to it.
function ssaDenseUpdate(a, b, n) {
    for (var i = 0; i < n; i++) b[i] = a[i] + 1;
}
for (var warm = 0; warm < 200; warm++) {
    var a = [], b = [];
    for (var i = 0; i < 64; i++) { a[i] = i; b[i] = 0; }
    ssaDenseUpdate(a, b, 64);
    for (var i = 0; i < 64; i++) if (b[i] !== i + 1) throw Error('dense numeric load');
    ssaDenseUpdate(a, a, 64);
    for (var i = 0; i < 64; i++) if (a[i] !== i + 1) throw Error('dense aliased load');
}
var calls = 0;
a[31] = { valueOf: function () { calls++; return 100; } };
ssaDenseUpdate(a, a, 64);
if (a[31] !== 101 || calls !== 1) throw Error('dense object recovery');
a[31] = '7';
ssaDenseUpdate(a, b, 64);
if (b[31] !== '71') throw Error('dense string recovery');
print('SSA dense numeric guard: PASS');
