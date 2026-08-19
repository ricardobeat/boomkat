// Returning from inside `try` with a `finally` used to drop one reference to
// the callee on every call: the completion path in ENDFINALLY decref'd the
// caller's result register without checking ACT_FLAG_BORROWED_CALLEE, which
// marks a slot holding a closure the frame borrowed and never incref'd.
//
// The refcount walked down one per call and the SIXTH call dispatched freed
// memory, surfacing as "object is not a function" (ASAN: use-after-poison in
// is_callable from try_fast_compiled_call). Every case here therefore loops
// past six iterations -- fewer would pass against the bug.
var failures = 0;
function eq(label, got, want) {
    if (got !== want) { print("FAIL " + label + ": got " + got + " want " + want); failures++; }
}

// The original repro: a borrowed global binding, called well past the
// threshold where the reference count would have hit zero.
function tf(i) { try { return "t" + i; } finally { } }
var r = null;
for (var i = 0; i < 20; i++) { r = tf(i); }
eq("borrowed callee", r, "t19");

// A finally that returns must win over the try's return.
function overridden() { try { return "a"; } finally { return "b"; } }
for (var i = 0; i < 20; i++) { r = overridden(); }
eq("finally overrides return", r, "b");

// Nested finallys chain the pending return through each level.
function nested() { try { try { return "in"; } finally { } } finally { } }
for (var i = 0; i < 20; i++) { r = nested(); }
eq("nested finally", r, "in");

// Constructors take the `this` binding rather than the return value, and the
// borrowed-slot rule applies to that write too.
function C() { this.v = "c"; try { return; } finally { } }
for (var i = 0; i < 20; i++) { r = new C(); }
eq("constructor through finally", r.v, "c");

// A heap-allocated return value exercises the pinned-transfer branch.
function objret(i) { try { return { v: i }; } finally { } }
for (var i = 0; i < 20; i++) { r = objret(i); }
eq("object return", r.v, 19);

// Throwing through a finally must still unwind normally.
function thrower() { try { throw new Error("x"); } finally { } }
var caught = 0;
for (var i = 0; i < 20; i++) { try { thrower(); } catch (e) { caught++; } }
eq("throw through finally", caught, 20);

// A method call reaches the same completion path by a different callee shape.
var obj = { m: function (i) { try { return "m" + i; } finally { } } };
for (var i = 0; i < 20; i++) { r = obj.m(i); }
eq("method callee", r, "m19");

print(failures === 0 ? "test_return_through_finally: all passed"
                     : "test_return_through_finally: " + failures + " FAILED");
