// for-in / for-of heads are ASSIGNMENT positions, not declarations.
//
// Two behaviours are covered:
//  1. Strict-only: a bare identifier target that resolves to no binding must
//     throw ReferenceError at runtime (not create an implicit global). It
//     throws only when an iteration actually happens, so an empty iterable is
//     accepted -- the assignment never executes.
//  2. The target must actually receive the value and keep it after the loop.
//     for-in previously published the key with an initialization store placed
//     BEFORE the exhaustion test, so the final no-key step overwrote the
//     target with undefined.
//
// Runs unmodified under node. The directive prologue matters there: node runs
// .js files as sloppy CommonJS, and the undeclared-target cases below only
// throw in strict code. This engine is strict-only, so the directive is a
// no-op for it.
'use strict';
if (typeof print === 'undefined') { var print = function (s) { console.log(s); }; }

var pass = 0, fail = 0;
function assert(cond, msg) {
  if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}
// Returns the constructor name of whatever `fn` throws, or 'NOTHROW'.
function throwKind(fn) {
  try { fn(); } catch (e) { return e.constructor.name; }
  return 'NOTHROW';
}

// --- 1. Undeclared bare target: ReferenceError at runtime ---------------
assert(throwKind(function () { eval('for (undeclared_a in {a:1}) {}'); }) === 'ReferenceError',
  'for-in undeclared bare identifier must throw ReferenceError');
assert(throwKind(function () { eval('for (undeclared_b of [1]) {}'); }) === 'ReferenceError',
  'for-of undeclared bare identifier must throw ReferenceError');
assert(throwKind(function () { eval('(function(){ for (undeclared_c in {a:1}) {} })()'); }) === 'ReferenceError',
  'for-in undeclared bare identifier inside a function must throw');
assert(throwKind(function () { eval('(function(){ for (undeclared_d of [1]) {} })()'); }) === 'ReferenceError',
  'for-of undeclared bare identifier inside a function must throw');

// The implicit global must not have been created as a side effect.
assert(typeof undeclared_a === 'undefined' && typeof undeclared_b === 'undefined',
  'a rejected for-in/of target must not create an implicit global');

// Destructuring targets naming undeclared bindings throw too.
assert(throwKind(function () { eval('for ([undeclared_e] of [[1]]) {}'); }) === 'ReferenceError',
  'for-of array-pattern with undeclared element must throw ReferenceError');
assert(throwKind(function () { eval('for ({m: undeclared_f} of [{m:1}]) {}'); }) === 'ReferenceError',
  'for-of object-pattern with undeclared target must throw ReferenceError');
assert(throwKind(function () { eval('for ([undeclared_g] in {ab:1}) {}'); }) === 'ReferenceError',
  'for-in array-pattern with undeclared element must throw ReferenceError');

// --- 2. Empty iterable: the assignment never runs, so no throw ----------
assert(throwKind(function () { eval('for (never_assigned_a in {}) {}'); }) === 'NOTHROW',
  'for-in over an empty object must not throw for an undeclared target');
assert(throwKind(function () { eval('for (never_assigned_b of []) {}'); }) === 'NOTHROW',
  'for-of over an empty array must not throw for an undeclared target');

// --- 3. Declared bare targets receive and RETAIN the value -------------
var y1;
for (y1 in { a: 1 }) {}
assert(y1 === 'a', 'for-in must leave the last key in a declared var target, got ' + y1);

var y2;
for (y2 of [7]) {}
assert(y2 === 7, 'for-of must leave the last value in a declared var target, got ' + y2);

let y3;
for (y3 in { a: 1 }) {}
assert(y3 === 'a', 'for-in must assign a declared let target, got ' + y3);

// Function-local var: the target is register-cached, so the loop must write
// the home register, not just the env slot.
function localVarTarget() { var q; for (q in { a: 1 }) {} return q; }
assert(localVarTarget() === 'a', 'for-in must assign a function-local var target');

function localVarTargetOf() { var q; for (q of [3]) {} return q; }
assert(localVarTargetOf() === 3, 'for-of must assign a function-local var target');

// A parameter is a legal assignment target too.
function paramTarget(pp) { for (pp in { a: 1 }) {} return pp; }
assert(paramTarget() === 'a', 'for-in must assign a parameter target');

// Closed-over variable, written from an inner function.
var closed;
(function () { for (closed in { z: 1 }) {} })();
assert(closed === 'z', 'for-in must assign a closed-over var target');

// Multiple keys: the target holds the LAST key after the loop.
var k1, seen = '';
for (k1 in { a: 1, b: 2, c: 3 }) { seen += k1; }
assert(seen === 'abc', 'for-in must visit every key, got ' + seen);
assert(k1 === 'c', 'for-in target must retain the last key, got ' + k1);

// break / continue must not disturb the target.
var k2;
for (k2 in { a: 1, b: 2 }) { break; }
assert(k2 === 'a', 'for-in target after break must be the first key, got ' + k2);

var k3, seen3 = '';
for (k3 in { a: 1, b: 2 }) { if (k3 === 'a') { continue; } seen3 += k3; }
assert(seen3 === 'b', 'for-in continue must still visit later keys');

// --- 4. Declarations and non-identifier targets still work -------------
var d1 = '';
for (var vx in { a: 1, b: 2 }) { d1 += vx; }
assert(d1 === 'ab' && vx === 'b', 'for (var x in o) must still work');

var d2 = '';
for (let lx in { a: 1 }) { d2 += lx; }
assert(d2 === 'a', 'for (let x in o) must still work');

var d3 = 0;
for (const cx of [1, 2]) { d3 += cx; }
assert(d3 === 3, 'for (const x of a) must still work');

// Member and computed-member targets, in the same scope and following other
// for-in/for-of loops. A discarded member head used to leave the compiler's
// method-call receiver state set, so the next call in the same function was
// compiled as a method call and dispatched on a register nothing wrote
// ("string is not a function"); the loops below therefore share one scope on
// purpose, and each is followed by a call.
var mo = {};
for (mo.p in { a: 1 }) {}
assert(mo.p === 'a', 'for (o.p in x) must still work');

for (mo.q of [4]) {}
assert(mo.q === 4, 'for (o.p of a) after another member loop must work');

var ma = [];
for (ma[0] in { q: 1 }) {}
assert(ma[0] === 'q', 'for (a[0] in x) must still work');

var mi = 1;
for (ma[mi] of [5]) {}
assert(ma[1] === 5, 'for (a[i] of x) must still work');

// Nested member target, and a call immediately after the loop.
var mn = { a: {} };
for (mn.a.b in { z: 1 }) {}
assert(mn.a.b === 'z', 'for (o.a.b in x) must work');

// The member head must be re-evaluated each iteration.
var reArr = [{}, {}], reIdx = 0;
for (reArr[reIdx++].k in { x: 1, y: 1 }) {}
assert(reArr[0].k === 'x' && reArr[1].k === 'y',
  'a member head must be re-evaluated every iteration');

// Declared destructuring targets.
var dp, dq;
for ([dp, dq] of [[1, 2]]) {}
assert(dp === 1 && dq === 2, 'for ([p,q] of pairs) with declared targets must work');

var dm;
for ({ m: dm } of [{ m: 9 }]) {}
assert(dm === 9, 'for ({m: x} of objs) with a declared target must work');

var dnest;
for ({ a: [dnest] } of [{ a: [8] }]) {}
assert(dnest === 8, 'nested destructuring with a declared target must work');

var ddef;
for ([ddef = 5] of [[]]) {}
assert(ddef === 5, 'destructuring default with a declared target must work');

var drest;
for ([...drest] of [[1, 2]]) {}
assert(drest.length === 2, 'rest destructuring with a declared target must work');

function destructMemberTarget() { var o = {}; for ({ m: o.p } of [{ m: 4 }]) {} return o.p; }
assert(destructMemberTarget() === 4, 'for ({m: o.p} of objs) must work');

// Lexical declaration forms in the head.
for (let [lp, lq] of [[1, 2]]) {
  assert(lp === 1 && lq === 2, 'for (let [p,q] of pairs) must work');
}
for (const { m: cm } of [{ m: 1 }]) {
  assert(cm === 1, 'for (const {m} of objs) must work');
}

// --- 5. const target is still a runtime error --------------------------
assert(throwKind(function () { eval('const kc = 1; for (kc in {a:1}) {}'); }) !== 'NOTHROW',
  'for-in assignment to a const target must throw');
assert(throwKind(function () { eval('const kd = 1; for (kd of [1]) {}'); }) !== 'NOTHROW',
  'for-of assignment to a const target must throw');

// --- 6. Prototype chain and nesting ------------------------------------
function Ctor() {}
Ctor.prototype.inherited = 1;
var inst = new Ctor();
inst.own = 2;
var keys = [];
for (var pk in inst) { keys.push(pk); }
keys.sort();
assert(keys.join() === 'inherited,own', 'for-in must walk the prototype chain, got ' + keys.join());

var nk, nested = '';
for (nk in { a: 1 }) {
  for (nk in { b: 1 }) { nested += nk; }
  nested += nk;
}
assert(nested === 'bb', 'nested for-in sharing one target must work, got ' + nested);

print('forin_forof_assignment_target: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
