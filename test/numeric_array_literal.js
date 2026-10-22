function check(condition, message) {
    if (!condition) throw new Error(message);
}
function numbers() {
    return [0, 1, -1, -0, 1.25, 1 / 0, -1 / 0, 0 / 0, 1e40, 140737488355327];
}
var first = numbers();
var second = numbers();
check(first !== second && second.length === 10, 'fresh array and length');
check(Object.is(second[3], -0), 'negative zero');
check(second[4] === 1.25 && second[5] === Infinity && second[6] === -Infinity, 'double values');
check(Number.isNaN(second[7]) && second[8] === 1e40, 'NaN and large double');
check(second[9] === 140737488355327, 'fastint boundary');
first[1] = 99;
first.length = 0;
check(second[1] === 1 && second.length === 10, 'independent storage');
for (var i = 0; i < second.length; i++) {
    var descriptor = Object.getOwnPropertyDescriptor(second, String(i));
    check(descriptor.writable && descriptor.enumerable && descriptor.configurable, 'element attributes');
}

Object.defineProperty(Array.prototype, '0', {
    configurable: true,
    set: function () { throw new Error('inherited setter called'); }
});
try {
    check(numbers()[0] === 0, 'literal defines an own element');
} finally {
    delete Array.prototype[0];
}

var hole = [, 1];
check(!(0 in hole) && 1 in hole && hole.length === 2, 'holes use normal initialization');
var calls = 0;
function sideEffect() { calls++; return 9; }
var ordinary = [1, sideEffect(), ...[2, 3]];
check(calls === 1 && ordinary.join(',') === '1,9,2,3', 'evaluation and spread');
check([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16].length === 17, 'larger literal');

var body = '';
for (var i = 0; i < 300; i++) body += 'var v' + i + ' = "constant-' + i + '";';
body += 'return [1, 2, -0, 1 / 0];';
var wide = new Function(body)();
check(wide[0] === 1 && Object.is(wide[2], -0) && wide[3] === Infinity, 'wide constant index');

function defaultArray(a = [1, 2, 3]) { a[0]++; return a; }
check(defaultArray()[0] === 2 && defaultArray()[0] === 2, 'fresh default parameter');
for (var i = 0; i < 5000; i++) {
    var current = numbers();
    check(current[1] === 1 && Object.is(current[3], -0), 'collection and register reuse');
}
print('numeric array literal: PASS');
