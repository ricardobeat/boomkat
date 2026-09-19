function check(ok, message) { if (!ok) throw new Error(message); }
function args() { return Array.prototype.slice.call(arguments); }
function same(actual, expected, message) {
    check(actual.length === expected.length, message + ' length');
    for (var i = 0; i < actual.length; i++) check(actual[i] === expected[i], message + ' at ' + i);
}
var object = {v: 7}, symbol = Symbol('value');
var source = [1, 'dynamic' + 2, object, symbol, null, true];
same([0, ...source, 9], [0, 1, 'dynamic2', object, symbol, null, true, 9], 'array');
same(args(0, ...source, 9, ...source), [0].concat(source, [9], source), 'arguments');
same([...[], 1, ...[]], [1], 'empty');
same(args(...[object, 2, 3, symbol, 5, 6, 7, 8]),
    [object, 2, 3, symbol, 5, 6, 7, 8], 'temporary array source');
var many = [];
for (var i = 0; i < 3000; i++) many.push({value: i});
var copied = args(...many);
check(copied.length === many.length && copied[2999] === many[2999], 'valstack growth');
function Box() { this.values = args(...arguments); }
same(new Box(...source).values, source, 'construct');

// The factory can return an externally visible, partially consumed iterator.
var it = [10, 20, 30].values();
it.next();
var factoryCalls = 0;
var custom = {};
custom[Symbol.iterator] = function () { factoryCalls++; return it; };
same([...custom], [20, 30], 'partial iterator');
check(factoryCalls === 1 && it.next().done, 'exhausted iterator');
it = [40, 50].values();
same(args(...custom), [40, 50], 'factory call spread');
check(factoryCalls === 2 && it.next().done, 'call iterator exhausted');

var getterCalls = 0;
var getterSource = [2, 4];
Object.defineProperty(getterSource, Symbol.iterator, {get: function () {
    getterCalls++;
    getterSource[0]++;
    return Array.prototype.values;
}});
same([...getterSource], [3, 4], 'iterator getter');
same(args(...getterSource), [4, 4], 'call iterator getter');
check(getterCalls === 2, 'getter count');

// Undefined shares the dense-hole sentinel; both must preserve property semantics.
var sparse = [1, , 3];
var proto = Object.create(Array.prototype);
Object.defineProperty(proto, '1', {get: function () {return 8;}});
Object.setPrototypeOf(sparse, proto);
same([...sparse], [1, 8, 3], 'inherited index');
same(args(...sparse), [1, 8, 3], 'call inherited index');
same([... [undefined, 2]], [undefined, 2], 'explicit undefined');
var indexed = [1, 2, 3];
Object.defineProperty(indexed, '0', {get: function () {indexed[1] = 19; return 11;}});
same([...indexed], [11, 19, 3], 'indexed accessor');
same(args(...indexed), [11, 19, 3], 'call indexed accessor');

var iteratorPrototype = Object.getPrototypeOf([].values());
var originalNext = iteratorPrototype.next;
var nextCalls = 0;
try {
    iteratorPrototype.next = function () {nextCalls++; return originalNext.call(this);};
    same([... [3, 6]], [3, 6], 'patched next');
    same(args(...[3, 6]), [3, 6], 'call patched next');
    check(nextCalls === 6, 'next call count');
} finally { iteratorPrototype.next = originalNext; }
var throwing = [1, 2];
throwing[Symbol.iterator] = function () {throw object;};
var caught = 0;
try { [...throwing]; } catch (e) {if (e === object) caught++;}
try { args(...throwing); } catch (e) {if (e === object) caught++;}
check(caught === 2, 'factory throws');
for (var n = 0; n < 500; n++) {
    var fresh = [{n: n}, 'string:' + n];
    var out = [...fresh];
    var called = args(...fresh);
    check(out[0] === called[0] && called[1] === 'string:' + n, 'owned references');
}
print('PASS dense array spread');
