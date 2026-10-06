function check(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ': ' + actual);
}

function combine(a, b) { return a + b; }
function branch(a, b, which) {
    var x = a;
    var y = b;
    if (which) return combine(x, y);
    return combine(y, x) + x;
}
function loop(a, n) {
    var x = a;
    var result = 0;
    for (var i = 0; i < n; i++) result += x;
    return result;
}
function dependent(a) {
    var x = a;
    var y = x;
    return y + x;
}
function beforeInitialization(a) {
    var first = x;
    var x = a;
    return first === undefined ? x : -1;
}
function mutateParameter(a) {
    var x = a;
    a = 9;
    return x + a;
}
function mutateLocal(a) {
    var x = a;
    x++;
    return x + a;
}
var mapped = Function('a', 'var x=a; arguments[0]=9; return x+a;');
function captured(a) {
    var x = a;
    function change() { a = 9; }
    change();
    return x + a;
}
function evaluated(a) {
    var x = a;
    eval('a = 9');
    return x + a;
}
function retained(a, which) {
    var x = a;
    if (which) return x;
    return combine('', x);
}
function comparison(a, b) {
    var x = a;
    var y = b;
    if (x < y) return x;
    if (x === y) return y;
    return x + 1;
}

for (var iteration = 0; iteration < 1200; iteration++) {
    check(branch(2, 3, true), 5, 'branch true');
    check(branch(2, 3, false), 7, 'branch false');
    check(branch('a', 'b', true), 'ab', 'string order true');
    check(branch('a', 'b', false), 'baa', 'string order false');
    check(loop(3, 5), 15, 'loop');
    check(dependent(4), 8, 'dependent entry copy');
    check(beforeInitialization(4), 4, 'read before initialization');
    check(mutateParameter(4), 13, 'parameter mutation');
    check(mutateLocal(4), 9, 'local mutation');
    check(mapped(4), 13, 'mapped arguments');
    check(captured(4), 13, 'capture');
    check(evaluated(4), 13, 'eval');
    check(comparison(2, 3), 2, 'register comparison');
    check(comparison(3, 3), 3, 'equal comparison');
    check(comparison(4, 3), 5, 'immediate arithmetic');
}
var object = { valueOf: function () { return 6; } };
check(retained(object, true), object, 'object identity');
check(dependent(object), 12, 'numeric conversion');
check(retained('owned-' + iteration, true), 'owned-1200', 'string identity');
check(branch(2n, 3n, true), 5n, 'BigInt');
check(branch(undefined, 1, true) !== branch(undefined, 1, true), true, 'NaN');
check(Object.is(retained(-0, true), -0), true, 'negative zero');
check(Function('a', 'a', 'var x=a; if(x<0)return x; return x+1;')(2, 4), 5,
      'duplicate formal');
print('PASS: parameter aliases');
