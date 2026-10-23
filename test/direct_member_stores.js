// Direct constant-key member stores.
//
// `obj.name = v`, `obj.name op= v` and `obj.name++` now emit PUTPROPC, or
// PUTTHISC when the object is a fixed `this`, instead of leaving a key load
// and LDTHIS for fusion to rejoin across the right-hand side.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function C() { this.n = 0; }
C.prototype.f = function (o) {
    this.n++; this.n += 2; o.k = this.n; o.k *= 3; o.k--;
    var post = this.n++;
    return post + ':' + this.n + ':' + o.k;
};
var o = {};
eq(new C().f(o), '3:4:8', 'compound and update stores');

// The right-hand side may replace the object variable; the store keeps the old one.
var a = { v: 1 }, b = { v: 2 }, first = a;
a.v = (a = b, 10);
eq(first.v + ',' + b.v, '10,2', 'store target evaluated before the RHS');

// Setters and the assignment's value.
var log = [];
var s = { set x(v) { log.push(v); } };
eq((s.x = 5), 5, 'assignment value');
s.x += 1;
eq(log.join(), '5,NaN', 'setter sees compound result');

// A derived constructor's `this` is unbound before super(): reading it throws before the RHS runs.
class Base {}
var ran = false;
class D extends Base { constructor() { this.x = (ran = true); super(); } }
try { new D(); } catch (e) { eq(e instanceof ReferenceError, true, 'unbound this throws'); }
eq(ran, false, 'RHS not evaluated before the this check');

// An arrow's `this` is the enclosing one.
function Holder() { this.v = 0; var set = () => { this.v = 7; }; set(); }
eq(new Holder().v, 7, 'arrow this store');

// Strict stores to non-writable properties throw.
(function () {
    'use strict';
    var frozen = Object.freeze({ k: 1 });
    try { frozen.k = 2; eq(true, false, 'frozen store throws'); } catch (e) { eq(e instanceof TypeError, true, 'frozen store throws'); }
    try { frozen.k++; eq(true, false, 'frozen update throws'); } catch (e) { eq(e instanceof TypeError, true, 'frozen update throws'); }
})();

print('direct_member_stores: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
