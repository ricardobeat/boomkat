// Threaded NEW_OBJ of lean constructors, and calls builtins re-dispatch.
//
// NEW_OBJ used to run in the threaded loop only for constructors simple
// enough to replay from their store caches. Any lean base constructor now
// runs on a lean frame holding the new object as `this`. A call that
// Function.prototype.call or apply re-dispatches used to bail to the switch
// before the builtin ran; the loop now enters a lean callee itself, or hands
// the call to vm_dispatch.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// Constructors that return a primitive, an object, or nothing.
function Prim(x) { this.x = x; if (x > 1000) return 5; return 7; }
function Obj(x) { this.x = x; return x & 1 ? { odd: x } : undefined; }
function Branchy(x) { if (x & 1) this.a = x; else this.b = x; }
var s = 0;
for (var i = 0; i < 300; i++) {
    s += new Prim(i).x;
    var o = new Obj(i);
    s += (i & 1) ? o.odd : o.x;
    var b = new Branchy(i);
    s += (i & 1) ? b.a : b.b;
}
eq(s, 3 * 299 * 300 / 2, 'constructor results');

// Reassigning the prototype after warm-up is seen by new instances.
function P() { this.v = arguments.length; }
P.prototype.kind = 'one';
for (var i = 0; i < 200; i++) new P(1, 2);
P.prototype = { kind: 'two' };
var p = new P(1, 2, 3);
eq(p.kind + p.v, 'two3', 'prototype reassigned');
eq(p instanceof P, true, 'instanceof after reassignment');

// A throw from a constructor reaches the caller's handler.
function Thrower(x) { this.x = x; if (x == 150) throw new RangeError('x'); }
var caught = 0;
for (var i = 0; i < 300; i++) { try { new Thrower(i); } catch (e) { caught += e instanceof RangeError; } }
eq(caught, 1, 'constructor throw');

// call and apply into lean, builtin and non-lean targets.
function add(a, b) { return this.base + a + b; }
function addArgs() { return this.base + arguments.length; }
function* gen() { yield this.base; }
var ctx = { base: 10 }, t = 0;
for (var i = 0; i < 300; i++) {
    t += add.call(ctx, 1, 2) + add.apply(ctx, [3, 4]) + addArgs.apply(ctx, [1, 2, 3]);
    t += Math.max.apply(null, [i, 1]) + gen.call(ctx).next().value;
}
eq(t, 300 * (13 + 17 + 13 + 10) + 299 * 300 / 2 + 1, 'call and apply targets');


// A primitive receiver for a sloppy target is boxed by the general entry.
function kind() { return typeof this; }
for (var i = 0; i < 100; i++) eq(kind.call(5), 'object', 'boxed receiver');

// A throw from a re-dispatched call is caught where the call stands.
function bad() { throw new TypeError('bad'); }
var tc = 0;
for (var i = 0; i < 200; i++) { try { bad.call(null); } catch (e) { tc += e instanceof TypeError; } }
eq(tc, 200, 're-dispatched throw');

// Re-dispatched calls in a tail position and through bound functions.
function tail(a) { return add.call(ctx, a, 1); }
var bound = add.bind(ctx, 5);
var tt = 0;
for (var i = 0; i < 200; i++) tt += tail(i) + bound.call(null, 1);
eq(tt, 200 * 11 + 199 * 200 / 2 + 200 * 16, 'tail and bound');

print('threaded_construct_redispatch: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
