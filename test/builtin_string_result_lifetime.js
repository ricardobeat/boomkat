// A builtin's string result moves from its counted slot into a register,
// which holds no count: the string must stay alive while only registers and
// locals read it, across allocation and the zero-count flush.
function check(actual, expected, what) {
    if (actual !== expected) throw new Error(what + ': expected ' + expected + ', got ' + actual);
}
var base = 'abcdefghijklmnopqrstuvwxyz0123456789';
function churn(n) {
    var junk = null;
    for (var i = 0; i < n; i++) junk = [{ i: i }, 'j' + i, [i]];
    return junk;
}
for (var r = 0; r < 300; r++) {
    var a = base.substring(r % 10, 20 + r % 7);
    var b = (base + r).slice(3);
    var c = ('x' + r).toUpperCase();
    var d = base.charAt(r % 36) + base.substring(5, 9 + r % 3);
    churn(400);
    check(a, base.substring(r % 10, 20 + r % 7), 'substring ' + r);
    check(b, (base + r).slice(3), 'slice ' + r);
    check(c, 'X' + r, 'upper ' + r);
    check(d.length, 5 + r % 3, 'concat ' + r);
}
print('ok');
