// Pooled-activation stale pointer fields (Activation.async_promise).
//
// vm.activations[] is a pool indexed by call depth and reused WITHOUT zeroing,
// so a raw pointer field on Activation is only sound if EVERY push site writes
// it. Activation.async_promise was not written by the getter-invoke path
// (vm_core.c3) or either setter-invoke path (vm_property.c3).
//
// That matters because mark_activation_fields() marks async_promise on every
// GC for every activation below activation_count, WITHOUT any ACT_FLAG_ASYNC
// guard (every functional read of the field IS flag-guarded; the GC mark is
// the one that is not). Sequence that broke the heap:
//
//   1. An async function runs at depth D. Its frame holds the outer Promise in
//      activations[D].async_promise, then returns and the frame is popped —
//      the field is left dangling, by design, since nothing releases it.
//   2. The Promise settles, loses its last real root, and is swept.
//   3. A getter runs at the same depth D. Its push never wrote async_promise,
//      so activations[D] inherited the freed pointer.
//   4. A safepoint GC inside the getter body marks it: mark_hobject writes
//      set_reachable() INTO FREED MEMORY and then drains the object's recycled
//      prototype/property words as if they were live references.
//   5. sweep() then free()s a pointer it never allocated.
//
// Symptom before the fix: SIGABRT, "pointer being freed was not allocated",
// inside Heap.sweep — with no JS-visible wrong answer, so the assertions below
// are NOT what catches it. The process dying is. Neither half reproduces
// alone: an async-only or getter-only version of this loop exits cleanly; the
// interleave at a matching call depth is what is required.
//
// This is GC-schedule sensitive. Adding even one more live function object
// before the loop shifts the collection point enough to hide the crash, which
// is why `assert` below is a late function EXPRESSION rather than a hoisted
// declaration, and why the loops run before anything else is defined. Keep it
// that way, and re-verify against an unfixed build if you edit this file.
//
// All activation pushes now funnel through activation_begin() (vm_core.c3),
// which clears async_promise, async_gen_state and new_target.

var pass = 0, fail = 0;
var assert;

var sink = [];
function deep(n, f) { if (n === 0) return f(); return deep(n - 1, f); }

async function mkPromise(x) { return x + 1; }

var getterObj = {};
Object.defineProperty(getterObj, 'g', { get: function () {
    // Allocate hard so a safepoint GC lands while this activation is live.
    var s = 0;
    for (var i = 0; i < 4000; i++) { s += ({ k: i, arr: [i, i + 1] }).k; }
    return s;
}});

var getterBad = 0;
for (var round = 0; round < 200; round++) {
    // Async frame at depth 30 — parks its Promise in activations[30].
    deep(30, function () { return mkPromise(round); });
    // Churn so the settled Promise is swept and its slot recycled.
    for (var j = 0; j < 200; j++) { sink.push({ p: j }); }
    if (sink.length > 3000) { sink = []; }
    // Getter at the SAME depth 30 — inherits the pooled slot.
    var v = deep(30, function () { return getterObj.g; });
    if (typeof v !== 'number') { getterBad++; }
}

// Same interleave, driving the setter-invoke paths in vm_property.c3.
var setterRuns = 0, setterBad = 0;
var setterObj = {};
Object.defineProperty(setterObj, 's', { set: function (val) {
    var s = 0;
    for (var i = 0; i < 4000; i++) { s += ({ k: i, arr: [i, i + 1] }).k; }
    setterRuns++;
    if (typeof val !== 'number') { setterBad++; }
}});

var setterWrites = 0;
for (var r2 = 0; r2 < 200; r2++) {
    deep(30, function () { return mkPromise(r2); });
    for (var j2 = 0; j2 < 200; j2++) { sink.push({ q: j2 }); }
    if (sink.length > 3000) { sink = []; }
    deep(30, function () { setterObj.s = r2; });
    setterWrites++;
}

// Same interleave, driving the constructor push path in vm_calls.c3.
function Ctor() {
    var s = 0;
    for (var i = 0; i < 3000; i++) { s += ({ k: i }).k; }
    this.v = s;
}
var ctorBad = 0;
for (var r3 = 0; r3 < 150; r3++) {
    deep(25, function () { return mkPromise(r3); });
    for (var j3 = 0; j3 < 200; j3++) { sink.push({ t: j3 }); }
    if (sink.length > 3000) { sink = []; }
    var inst = deep(25, function () { return new Ctor(); });
    if (typeof inst.v !== 'number') { ctorBad++; }
}

// new_target is cleared by the same helper: a getter reusing a slot that a
// `new` just occupied must still see an ordinary receiver, not the instance.
var ntObj = {};
var ntBad = 0;
Object.defineProperty(ntObj, 'nt', {
    get: function () { if (this !== ntObj) { ntBad++; } return 1; }
});
for (var m = 0; m < 50; m++) {
    deep(10, function () { return new Ctor(); });
    deep(10, function () { return ntObj.nt; });
}

assert = function (cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } };

assert(getterBad === 0, getterBad + " getter calls at an async frame's pooled depth returned a non-number");
assert(setterRuns === setterWrites, "setter ran " + setterRuns + "/" + setterWrites + " times");
assert(setterBad === 0, setterBad + " setter calls received a non-number");
assert(ctorBad === 0, ctorBad + " constructions at an async frame's pooled depth produced a bad instance");
assert(ntBad === 0, ntBad + " getter calls after a construct saw the wrong receiver");

print('act_pooled_ptr_fields: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
