// Regression: Reflect.apply / Function.prototype.apply drained one reference
// per call from both the callee and the receiver.
//
// apply_call re-dispatches a non-lightfunc callable by writing the target into
// regs[base_reg - 2], the receiver into regs[base_reg - 1] and the extracted
// arguments into regs[base_reg + i], then asking the VM to run the call again.
// Those slots all live inside the calling frame's decref window, so the frame
// releases each of them when it overwrites them or unwinds. The stores were raw
// copies: the target and receiver were copies of registers that keep their own
// reference, and the arguments had been read out of the argument array with a
// property get that does not incref, so each call handed the frame a reference
// nobody had taken.
//
// One count per call meant the values survived a couple of iterations and then
// hit zero and were freed and recycled. Which of them died first depended on
// register allocation, so the same loop failed as either "Reflect.apply called
// on non-callable" (the callee recycled into something uncallable) or "this is
// not a Date" (the receiver recycled), always on the third or fourth call —
// never on the first, which is why a single-shot test saw nothing.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } }

// --- Reflect.apply onto a BUILTIN_FN object, no arguments ------------------
// Date.prototype.toJSON is an object-wrapped builtin, so it takes the
// re-dispatch branch rather than the lightfunc branch. Both the function and
// the date are held only by loop-outer vars, so a drained count frees them.
var d = new Date(Date.UTC(2020, 0, 1));
var toJSON = Date.prototype.toJSON;
var expected = '2020-01-01T00:00:00.000Z';
var bad = 0;
for (var i = 0; i < 30; i++) {
    if (Reflect.apply(toJSON, d, []) !== expected) bad++;
}
assert(bad === 0, 'Reflect.apply(Date.prototype.toJSON): ' + bad + ' of 30 calls wrong');
assert(d instanceof Date && d.getTime() === Date.UTC(2020, 0, 1),
       'receiver survived 30 Reflect.apply calls');

// The inline (non-hoisted) form allocates registers differently and used to
// fail with the other error message.
bad = 0;
for (var i = 0; i < 30; i++) {
    if (Reflect.apply(Date.prototype.toJSON, d, []) !== expected) bad++;
}
assert(bad === 0, 'Reflect.apply with inline callee: ' + bad + ' of 30 calls wrong');

// --- Function.prototype.apply, same path -----------------------------------
bad = 0;
for (var i = 0; i < 30; i++) {
    if (toJSON.apply(d, []) !== expected) bad++;
}
assert(bad === 0, 'Date.prototype.toJSON.apply: ' + bad + ' of 30 calls wrong');

// --- arguments extracted from the array must arrive owned ------------------
// Each argument is read out of the array without an incref; the array is the
// only other holder, and it is rebuilt every iteration so nothing else pins the
// elements.
var joiner = Array.prototype.concat;
bad = 0;
for (var i = 0; i < 30; i++) {
    var argA = { toString: function () { return 'a'; } };
    var argB = { toString: function () { return 'b'; } };
    var out = Reflect.apply(joiner, [i], [argA, argB]);
    if (out.length !== 3 || out[0] !== i || String(out[1]) !== 'a' || String(out[2]) !== 'b') bad++;
}
assert(bad === 0, 'Reflect.apply argument lifetime: ' + bad + ' of 30 calls wrong');

// --- compiled-function target through the same helper ----------------------
function addV(a, b) { return this.v + a + b; }
var recv = { v: 100 };
bad = 0;
for (var i = 0; i < 30; i++) {
    if (Reflect.apply(addV, recv, [1, 2]) !== 103) bad++;
}
assert(bad === 0, 'Reflect.apply onto a compiled function: ' + bad + ' of 30 calls wrong');
assert(recv.v === 100, 'compiled-function receiver survived 30 calls');

// --- the receiver must not be recycled into another live value -------------
// A drained receiver was freed and its block reused by the next allocation, so
// a later read saw someone else's object rather than a clean crash.
var probe = { tag: 'probe', n: 0 };
var hasOwn = Object.prototype.hasOwnProperty;
bad = 0;
for (var i = 0; i < 40; i++) {
    if (Reflect.apply(hasOwn, probe, ['tag']) !== true) bad++;
    probe.n = i;
    if (probe.tag !== 'probe' || probe.n !== i) bad++;
}
assert(bad === 0, 'receiver identity across 40 applies: ' + bad + ' mismatches');

print('apply_redispatch_refcount: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
