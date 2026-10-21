// Indexed [[Get]], [[Set]], [[HasProperty]] and [[Delete]] in the Array builtins.
//
// The builtins looked an index up as a string key in the named table only, so
// an element held in an array's dense part was invisible to their [[Set]]: a
// splice shifting it ran an inherited setter instead of overwriting it. Every
// lookup interned the index and probed each prototype's table too. They now
// share HObject.own_index and find_index_holder, which read the dense part and
// consult a named table only where an index can live in it.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function throwsType(f) {
    try { f(); } catch (e) { return e instanceof TypeError; }
    return false;
}

// Large splices and unshifts over plain arrays.
var a = [];
for (var i = 0; i < 2000; i++) a.push(i);
for (var r = 0; r < 50; r++) { a.splice(10, 3); a.splice(500, 0, 'x', 'y', 'z'); }
eq(a.length, 2000, 'splice keeps the length');
eq(a[10] + ',' + a[500] + ',' + a[1999], '160,x,1999', 'splice moves the elements');
a.unshift('u'); a.reverse(); a.copyWithin(0, 1, 3);
eq(a[0] + ',' + a.length, '1998,2001', 'reverse and copyWithin');

// An own dense element is overwritten in place; the inherited setter is not run.
var setterHits = 0;
Object.defineProperty(Object.prototype, '0', {
    set: function (v) { setterHits++; }, get: function () { return 'inherited'; }, configurable: true
});
var b = [5, 6, 7];
b.splice(0, 1);
eq(b.join() + '|' + setterHits, '6,7|0', 'own element shadows an inherited setter');
var c = [];
c.length = 3;
Array.prototype.fill.call(c, 9, 0, 1);
eq(setterHits + ':' + c.hasOwnProperty(0), '1:false', 'a hole defers to the inherited setter');
eq([, 1].indexOf('inherited'), 0, 'a hole reads through to the inherited getter');
delete Object.prototype[0];

// An inherited read-only element blocks the store; an inherited writable one
// is shadowed.
var ro = Object.create(Array.prototype);
Object.defineProperty(ro, '1', { value: 'ro', writable: false });
var d = [1, 2, 3];
Object.setPrototypeOf(d, ro);
delete d[1];
eq(throwsType(function () { d.fill(0); }), true, 'inherited read-only element throws');
var w = Object.create(Array.prototype);
w[1] = 'proto';
var e = [1, , 3];
Object.setPrototypeOf(e, w);
e.fill(4);
eq(e.join() + '|' + w[1], '4,4,4|proto', 'inherited writable element is shadowed');

// A named index entry is the property; its dense mirror must follow it.
var f = [1, 2, 3, 4];
Object.defineProperty(f, '1', { value: 'n', writable: true, enumerable: false, configurable: true });
f.splice(0, 1);
var seen = [];
f.forEach(function (v) { seen.push(v); });
eq(seen.join(), 'n,3,4', 'named index entries shift with the dense part');
var g = [1, 2, 3];
Object.defineProperty(g, '2', { value: 3, writable: true, configurable: false });
eq(throwsType(function () { g.length = 0; g.splice(0, 3); }), true, 'non-configurable index survives');
eq(g.length + ':' + g[2], '3:3', 'length stops above it');
var h = [1, 2, 3];
h.splice(1, 1, undefined);
eq(h.length + ':' + (1 in h) + ':' + h[1], '3:true:undefined', 'undefined is a present element');

// Array-likes keep integer keys beyond the array-index range as names.
var big = { '9007199254740990': 'x', length: Math.pow(2, 53) - 1 };
eq(Array.prototype.pop.call(big) + ':' + ('9007199254740990' in big), 'x:false', 'integer keys near 2^53');

// Element moves (shift, unshift, splice, copyWithin) on a dense array are a
// block move of its storage; holes move as holes and objects stay alive.
var objs = [];
for (var i = 0; i < 300; i++) objs.push({ v: i });
delete objs[5];
for (var r = 0; r < 100; r++) { objs.push(objs.shift()); objs.unshift(objs.pop()); }
objs.splice(1, 0, { v: 'a' }, { v: 'b' });
objs.copyWithin(250, 0, 10);
var tags = [];
for (var i = 0; i < 12; i++) tags.push(i in objs ? objs[i].v : 'hole');
eq(tags.join(), '0,a,b,1,2,3,4,hole,6,7,8,9', 'moves keep order and holes');
eq(objs[257] === undefined && !(257 in objs) && objs[258].v, 6, 'copyWithin moves holes');
var garbage = [];
for (var i = 0; i < 20000; i++) garbage.push([i]);
garbage = null;
eq(objs[299 + 2].v + objs[0].v, 299, 'moved elements survive a collection');

var sparse = [1, 2];
sparse.length = 100000000;
sparse.unshift(0);
eq(sparse.length + ':' + sparse[2], '100000001:2', 'unshift across a sparse length');

// Moves through a proxy keep the spec's trap order: HasProperty before Get,
// from the top down for unshift.
var log = [];
var target = ['a', , 'c'];
var traced = new Proxy(target, {
    has: function (t, k) { log.push('has' + String(k)); return k in t; },
    get: function (t, k) { if (k !== 'length') log.push('get' + String(k)); return t[k]; }
});
Array.prototype.unshift.call(traced, 'z');
eq(log.join(), 'has2,get2,has1,has0,get0', 'unshift trap order');
eq(target.join(), 'z,a,,c', 'unshift through a proxy');

print('array_index_semantics: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
