// Threaded stores that miss the site cache.
//
// A PUTTHISC or PUTPROPC whose cache names another receiver, or whose
// receiver has no room left, used to bail to the switch every time. Such a
// store now runs by lookup in the threaded loop: an own writable property, or
// a new one when the first holder of the key on the chain is a writable data
// property. Accessors and read-only properties still take the full [[Set]].

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// A polymorphic constructor site: each receiver adds keys from another shape.
function Base(k) { this.k = k; }
function A() { Base.call(this, 'a'); this.x = 1; }
function B() { this.y = 2; Base.call(this, 'b'); }
var objs = [];
for (var i = 0; i < 300; i++) objs.push(i & 1 ? new A() : new B());
eq(objs[1].k + objs[1].x, 'a1', 'polymorphic add on A');
eq(objs[2].k + objs[2].y, 'b2', 'polymorphic add on B');

// Receivers past the hash threshold keep growing through one site.
function Wide() { for (var j = 0; j < 12; j++) this['p' + j] = j; }
Wide.prototype.add = function (v) { this.extra = v; return this; };
var sum = 0;
for (var i = 0; i < 200; i++) sum += new Wide().add(i).extra;
eq(sum, 19900, 'append to a large receiver');
eq(new Wide().add(5).p11, 11, 'earlier keys survive');

// An inherited writable data property is shadowed, not overwritten.
function Proto() {}
Proto.prototype.v = 'proto';
Proto.prototype.set = function (v) { this.v = v; };
var p;
for (var i = 0; i < 100; i++) { p = new Proto(); p.set(i); }
eq(p.v, 99, 'own copy written');
eq(Proto.prototype.v, 'proto', 'prototype untouched');

// An inherited setter runs; an inherited read-only property blocks the add.
var log = 0;
function S() {}
Object.defineProperty(S.prototype, 'v', { set: function (x) { log += x; } });
function R() {}
Object.defineProperty(R.prototype, 'v', { value: 'ro', writable: false });
function store(o, x) { o.v = x; return o; }
for (var i = 0; i < 100; i++) { store(new Proto(), 1); store(new S(), 1); store(new R(), 1); }
eq(log, 100, 'inherited setter called');
eq(store(new R(), 1).v, 'ro', 'read-only inherited blocks the store');
eq(Object.keys(store(new S(), 1)).length, 0, 'setter adds no own key');

print('threaded_put_lookup: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
