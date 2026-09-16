// TypedArray elements are enumerable own data properties (§10.4.5.1).
//
// They live in the backing buffer rather than in the named property table or
// the flat array part, so every surface that walks an object's own properties
// has to ask for them specifically. A surface that only scans the two storage
// areas reports a TypedArray as having no elements at all.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(JSON.stringify(a) === JSON.stringify(b),
                          m + ' (got ' + JSON.stringify(a) + ', want ' + JSON.stringify(b) + ')'); }

var ta = new Int32Array([1, 2, 3]);

eq(Object.keys(ta), ['0', '1', '2'], 'Object.keys');
eq(Object.getOwnPropertyNames(ta), ['0', '1', '2'], 'Object.getOwnPropertyNames');
eq(Object.values(ta), [1, 2, 3], 'Object.values');
eq(Object.entries(ta), [['0', 1], ['1', 2], ['2', 3]], 'Object.entries');
eq(Object.assign({}, ta), { 0: 1, 1: 2, 2: 3 }, 'Object.assign');
eq({ ...ta }, { 0: 1, 1: 2, 2: 3 }, 'object spread');
eq(JSON.parse(JSON.stringify(ta)), { 0: 1, 1: 2, 2: 3 }, 'JSON.stringify');

ok(0 in ta, '`in` finds an in-bounds index');
ok(!(3 in ta), '`in` rejects an out-of-bounds index');
ok(ta.propertyIsEnumerable(0) === true, 'propertyIsEnumerable on an element');
ok(ta.propertyIsEnumerable(3) === false, 'propertyIsEnumerable out of bounds');
ok(ta.hasOwnProperty(0) === true, 'hasOwnProperty on an element');
ok(Object.hasOwn(ta, 0) === true, 'Object.hasOwn on an element');
ok(Object.hasOwn(ta, 3) === false, 'Object.hasOwn out of bounds');

// Object.hasOwn is HasOwnProperty, the same operation hasOwnProperty performs,
// so it has to see every exotic's own indices too.
var arr = [1, 2, 3];
ok(Object.hasOwn(arr, 0) === true, 'Object.hasOwn on a dense array index');
ok(Object.hasOwn(arr, 'length') === true, 'Object.hasOwn on array length');
var boxed = Object('abc');
ok(Object.hasOwn(boxed, 0) === true, 'Object.hasOwn on a string index');
(function () {
    ok(Object.hasOwn(arguments, 0) === true, 'Object.hasOwn on an arguments index');
})(1);

var d = Object.getOwnPropertyDescriptor(ta, 0);
ok(d !== undefined && d.value === 1, 'getOwnPropertyDescriptor reads the element');
ok(d.enumerable === true && d.writable === true && d.configurable === true,
   'an element descriptor is writable, enumerable and configurable');

// for-in walks the same key set.
var seen = [];
for (var k in ta) { seen.push(k); }
eq(seen, ['0', '1', '2'], 'for-in');

// Elements come before named string keys in [[OwnPropertyKeys]] order.
var mixed = new Int32Array([7, 8]);
mixed.extra = 'x';
eq(Object.keys(mixed), ['0', '1', 'extra'], 'elements sort before named keys');
eq(Object.values(mixed), [7, 8, 'x'], 'values follow key order');
eq({ ...mixed }, { 0: 7, 1: 8, extra: 'x' }, 'spread follows key order');

// Every element type round-trips as its own value type.
var big = new BigInt64Array([1n, 2n]);
eq(Object.keys(big), ['0', '1'], 'BigInt64Array keys');
ok(typeof Object.values(big)[0] === 'bigint', 'BigInt elements stay bigint');
ok(typeof ({ ...big })[0] === 'bigint', 'spread keeps bigint');

var f = new Float64Array([0.5, 1.5]);
eq(Object.values(f), [0.5, 1.5], 'Float64Array values');

// A detached buffer has no elements.
var dab = new ArrayBuffer(8);
var det = new Int32Array(dab);
dab.transfer();
eq(Object.keys(det), [], 'a detached view has no keys');
eq(Object.values(det), [], 'a detached view has no values');
eq(Object.assign({}, det), {}, 'a detached view copies nothing');
eq({ ...det }, {}, 'a detached view spreads to nothing');
ok(det.propertyIsEnumerable(0) === false, 'a detached view has no enumerable index');

// A length-tracking view reports its current length.
var rab = new ArrayBuffer(8, { maxByteLength: 16 });
var lt = new Int32Array(rab);
eq(Object.keys(lt), ['0', '1'], 'length-tracking keys before resize');
rab.resize(4);
eq(Object.keys(lt), ['0'], 'length-tracking keys after shrink');
eq(Object.values(lt), [0], 'length-tracking values after shrink');
rab.resize(16);
eq(Object.keys(lt), ['0', '1', '2', '3'], 'length-tracking keys after grow');

// An empty view has no element keys.
eq(Object.keys(new Int32Array(0)), [], 'an empty view has no keys');
eq(Object.values(new Int32Array(0)), [], 'an empty view has no values');

if (fail === 0) {
    print('PASS: TypedArray elements are own properties (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
