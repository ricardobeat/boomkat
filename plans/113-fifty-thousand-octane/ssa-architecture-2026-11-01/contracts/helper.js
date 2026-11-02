function callback(i) { return i + 0.5; }
function nativeHelper(o, n, fn) {
    var sum = 0.25;
    for (var i = 0; i < n; i++) {
        o.before = o.before + 1;
        sum = sum + fn(i);
        o.after = o.after + 1;
    }
    return sum;
}
var o = {before: 0, after: 0};
for (var warm = 0; warm < 96; warm++) {
    if (nativeHelper(o, 12, callback) !== 72.25) throw 'result';
}
if (o.before !== 1152 || o.after !== 1152) throw 'effects';
console.log('native helper mechanism: PASS');
