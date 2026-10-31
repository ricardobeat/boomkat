// Scalar homes must survive eviction and publish before coercion, helpers,
// branches and returns. Values that start as doubles/strings must lose any
// integer facts inherited from a previous definition or invocation.
function scalar(a, b, c) {
    var x = a | 0, y = b | 0, z = c | 0;
    x = (x ^ 0x5a5a) | 0;
    y = (y + x) | 0;
    z = (z ^ y) | 0;
    x = (x + z) | 0;
    return [x, y, z];
}
function recover(a, b) {
    var x = a | 0;
    x = (x ^ 123) | 0;
    var y = b & 7;
    return x + y;
}
function mutate(a, callback) {
    var x = a | 0;
    x = (x + 7) | 0;
    callback();
    return x;
}
function check(value, expected) {
    if (String(value) !== String(expected)) throw new Error(value + ' != ' + expected);
}
for (var i = 0; i < 2000; i++) {
    var x = (i ^ 0x5a5a) | 0, y = (i + 1 + x) | 0, z = ((i + 2) ^ y) | 0;
    check(scalar(i, i + 1, i + 2), [(x + z) | 0, y, z]);
    check(recover(i, i), (i ^ 123) + (i & 7));
}
var calls = 0;
check(recover(19, { valueOf: function () { calls++; return 10; } }), (19 ^ 123) + 2);
check(calls, 1);
check(recover(19, 4294967297), (19 ^ 123) + 1);
check(recover('19', '10'), (19 ^ 123) + 2);
check(scalar(3.5, true, '7'), scalar(3, 1, 7));
check(mutate(42, function () { calls++; }), 49);
check(calls, 2);
print('scalar cache: PASS');
