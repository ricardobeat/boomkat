// Reads at sites that see several receiver shapes, and entries filled from
// megamorphic hits: each must keep reading the slot the receiver's own layout
// names, and an entry for an inherited property must notice shadowing and
// prototype changes.
var pass = 0, fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) pass++;
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// x sits at a different slot in each layout.
function readX(o) { return o.x; }
var layouts = [{ x: 1 }, { a: 0, x: 2 }, { a: 0, b: 0, x: 3 }, { b: 0, x: 4, a: 0 },
               { c: 0, d: 0, e: 0, x: 5 }, { x: 6, y: 0 }];
var sum = 0;
for (var i = 0; i < 6000; i++) sum += readX(layouts[i % layouts.length]);
eq(sum, 1000 * 21, 'polymorphic own reads');

// More layouts than the set holds: the megamorphic cache answers the rest.
var many = [];
for (var k = 0; k < 12; k++) {
    var o = {};
    for (var j = 0; j < k; j++) o['p' + j] = 0;
    o.x = k;
    many.push(o);
}
sum = 0;
for (var i = 0; i < 12000; i++) sum += readX(many[i % 12]);
eq(sum, 1000 * 66, 'megamorphic own reads');

// An inherited method read, then shadowed by an own property, then replaced
// on the prototype.
function Base() {}
Base.prototype.m = function () { return 1; };
function callM(o) { return o.m(); }
var objs = [new Base(), new Base(), new Base()];
sum = 0;
for (var i = 0; i < 3000; i++) sum += callM(objs[i % 3]);
eq(sum, 3000, 'inherited method');
objs[1].m = function () { return 10; };
sum = 0;
for (var i = 0; i < 3000; i++) sum += callM(objs[i % 3]);
eq(sum, 1000 * 12, 'own property shadows the cached method');
Base.prototype.m = function () { return 100; };
sum = 0;
for (var i = 0; i < 3000; i++) sum += callM(objs[i % 3]);
eq(sum, 1000 * 210, 'prototype method replaced');

// A data property that becomes a getter at the same layout position.
function readV(o) { return o.v; }
var plain = { v: 1 }, other = { w: 0, v: 2 };
for (var i = 0; i < 2000; i++) readV(i & 1 ? plain : other);
Object.defineProperty(other, 'v', { get: function () { return 7; } });
eq(readV(other), 7, 'getter replaces a cached data property');
eq(readV(plain), 1, 'other shape still cached');

// Arrays and objects at one site, including length.
function readLen(o) { return o.length; }
var mixed = [[1, 2, 3], { length: 9 }, 'abcd', { a: 0, length: 5 }];
sum = 0;
for (var i = 0; i < 4000; i++) sum += readLen(mixed[i % 4]);
eq(sum, 1000 * 21, 'length across arrays, strings and objects');

// Deleting a property moves the object to a layout of its own.
var d1 = { x: 1, y: 2 }, d2 = { y: 3, x: 4 };
for (var i = 0; i < 2000; i++) readX(i & 1 ? d1 : d2);
delete d1.y;
d1.z = 5;
eq(readX(d1), 1, 'read after delete');
eq(readX(d2), 4, 'other shape after delete');

print('poly_read_ic: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
