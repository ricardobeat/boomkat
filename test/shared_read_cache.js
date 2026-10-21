// Megamorphic reads from the threaded handlers.
//
// A GETPROPC whose site cache holds another shape consults the heap's shared
// cache, and an own hit moves the site entry to the receiver's shape. Own
// entries read the receiver's slot at the cached index, so deletes, dictionary
// objects, accessors and prototype changes must all miss.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function make(i) {
    var o = {};
    // Eight shapes, each with `v` at a different index.
    for (var k = 0; k < (i & 7); k++) o['p' + k] = k;
    o.v = i;
    return o;
}
function readV(o) { return o.v; }
function sum(objs) { var s = 0; for (var r = 0; r < 4; r++) for (var i = 0; i < objs.length; i++) s += readV(objs[i]); return s; }

var objs = [];
for (var i = 0; i < 64; i++) objs.push(make(i));
eq(sum(objs), 4 * 2016, 'polymorphic own reads');

// A value changed after caching is read live.
objs[5].v = 1000;
eq(sum(objs), 4 * (2016 - 5 + 1000), 'updated value');

// Deleting turns an object into a dictionary; the property must vanish.
delete objs[9].v;
var s = 0;
for (var r = 0; r < 4; r++) s += readV(objs[9]) === undefined ? 1 : 0;
eq(s, 4, 'deleted own property');

// Another key deleted reorders a dictionary object's slots.
delete objs[10].p0;
eq(readV(objs[10]) + readV(objs[10]), 20, 'dictionary after other delete');

// An accessor on a same-shaped sibling is not served as data.
var acc = make(3);
delete acc.v;
Object.defineProperty(acc, 'v', { get: function () { return 'got'; }, configurable: true });
eq(readV(acc), 'got', 'accessor read');
eq(readV(acc), 'got', 'accessor read again');

// Prototype reads follow a changed prototype.
function P() {}
P.prototype.v = 'proto';
var kids = [];
for (var i = 0; i < 8; i++) { var c = new P(); for (var k = 0; k < i; k++) c['q' + k] = k; kids.push(c); }
var hits = 0;
for (var r = 0; r < 4; r++) for (var i = 0; i < kids.length; i++) if (readV(kids[i]) === 'proto') hits++;
eq(hits, 32, 'prototype reads');
Object.setPrototypeOf(kids[3], { v: 'other' });
eq(readV(kids[3]), 'other', 'setPrototypeOf');
P.prototype.v = 'changed';
eq(readV(kids[2]), 'changed', 'prototype value change');
kids[4].v = 'own';
eq(readV(kids[4]), 'own', 'own shadows prototype');

print('shared_read_cache: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
