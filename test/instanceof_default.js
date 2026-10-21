// instanceof without calling @@hasInstance.
//
// A callable, unbound right-hand side inheriting the intrinsic
// Function.prototype[@@hasInstance] runs OrdinaryHasInstance inline, in the
// switch and from the threaded handler through the megamorphic cache. Every
// way of leaving that case must still reach the general path.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}
function test(v, F) { return v instanceof F; }
function many(v, F) { var r; for (var i = 0; i < 4; i++) r = test(v, F); return r; }
function throws(v, F) { try { test(v, F); return 'none'; } catch (e) { return e.constructor.name; } }

function A() {}
function B() {}
B.prototype = Object.create(A.prototype);
var a = new A(), b = new B();
eq(many(a, A), true, 'direct instance');
eq(many(b, A), true, 'inherited instance');
eq(many(a, B), false, 'not an instance');
eq(many(A.prototype, A), false, 'own prototype is not an instance');
eq(many(1, A), false, 'primitive');
eq(many(null, A), false, 'null');
eq(many(test, Function), true, 'function instanceof Function');
eq(many([], Object), true, 'array instanceof Object');

class C {}
class D extends C {}
eq(many(new D(), C), true, 'class extends');

// Reassigning prototype after the caches filled.
var old = new A();
A.prototype = {};
eq(many(old, A), false, 'stale prototype');
eq(many(new A(), A), true, 'new prototype');

// A bound function tests its target.
var BA = B.bind(null);
eq(many(b, BA), true, 'bound function');

// An own or inherited @@hasInstance is called.
class E { static [Symbol.hasInstance](v) { return v === 42; } }
eq(many(42, E), true, 'static hasInstance');
eq(many({}, E), false, 'static hasInstance false');
function G() {}
Object.setPrototypeOf(G, { [Symbol.hasInstance]() { return true; } });
eq(many(1, G), true, 'swapped prototype hasInstance');
function H() {}
Object.defineProperty(H, Symbol.hasInstance, { value: function () { return 'yes'; } });
eq(many(0, H), true, 'own hasInstance coerced');

// A prototype getter is called, and a non-object prototype throws.
function P() {}
var PP = new Proxy(P, {});
eq(many(new P(), PP), true, 'proxy right-hand side');
function Q() {}
Q.prototype = 3;
eq(throws({}, Q), 'TypeError', 'primitive prototype throws');
eq(throws({}, {}), 'TypeError', 'non-callable throws');

// A proxy in the left operand's chain.
var viaProxy = Object.create(new Proxy(Object.create(P.prototype), {}));
eq(many(viaProxy, P), true, 'proxy on left chain');

// A non-callable object inheriting Function.prototype calls the intrinsic,
// which answers false.
eq(many({}, Object.create(Function.prototype)), false, 'non-callable function-like');

print('instanceof_default: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
