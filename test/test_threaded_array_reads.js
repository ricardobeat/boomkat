function eq(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ': ' + actual + ' !== ' + expected);
}
function read(a, i) { return a[i]; }
function length(a) { return a.length; }
var a = [11, 22, 33];
for (var warm = 0; warm < 100; warm++) {
    eq(read(a, 1), 22, 'dense');
    eq(length(a), 3, 'length');
}
var gets = 0;
Object.defineProperty(a, '1', { configurable: true, get: function () { gets++; return 71; } });
eq(read(a, 1), 71, 'own indexed getter');
eq(gets, 1, 'getter count');
delete a[1];
var proto = Object.create(Array.prototype);
Object.defineProperty(proto, '1', { configurable: true, get: function () { gets++; return 81; } });
Object.setPrototypeOf(a, proto);
eq(read(a, 1), 81, 'inherited indexed getter');
eq(gets, 2, 'inherited getter count');
Object.defineProperty(a, '1', { value: undefined, configurable: true, writable: true });
eq(read(a, 1), undefined, 'own undefined shadows prototype');
eq(gets, 2, 'shadowed getter count');
a.length = 1;
eq(length(a), 1, 'truncated length');
eq(read(a, 2), undefined, 'truncated element');
Object.setPrototypeOf(a, Array.prototype);
a.push(42);
eq(length(a), 2, 'grown length');
eq(read(a, 1), 42, 'grown element');
a[-1] = 93;
a[1.5] = 94;
eq(read(a, -1), 93, 'negative key');
eq(read(a, 1.5), 94, 'fractional key');
eq(read(a, '1'), 42, 'string index');
var keys = 0;
eq(read(a, { toString: function () { keys++; return '1'; } }), 42, 'coerced key');
eq(keys, 1, 'key coercion count');
var traps = 0;
var proxy = new Proxy(a, { get: function (target, key) { traps++; return key === 'length' ? 99 : 98; } });
eq(read(proxy, 0), 98, 'proxy index');
eq(length(proxy), 99, 'proxy length');
eq(traps, 2, 'proxy trap count');
var object = { marker: 123 };
var values = [object, 'a string that is not a builtin', Symbol('element'), 12345678901234567890n];
for (var j = 0; j < 1000; j++) {
    for (var k = 0; k < values.length; k++) eq(read(values, k), values[k], 'heap element');
}
function alias(a, i) { a = a[i]; return a; }
eq(alias([object], 0), object, 'destination aliases receiver');
function argument(x) { x = 17; return arguments[0]; }
eq(argument(1), 17, 'mapped arguments fallback');
eq(read(new Uint8Array([7]), 0), 7, 'typed array fallback');
eq(read('abc', 1), 'b', 'string fallback');
var count = 0;
var moving = [1, 2, 3];
for (var n = 0; n < moving.length; n++) { count++; if (n === 0) moving.length = 1; }
eq(count, 1, 'loop observes length mutation');
print('PASS threaded array reads');
