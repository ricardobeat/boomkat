// A setter invocation stages [callee, this] above the caller's registers, and
// those two slots must not survive the call.
//
// PUTPROP invokes an accessor's setter by writing the setter function and the
// receiver into valstack slots at `act.bottom + num_regs`, past the end of the
// frame. The write is raw, since tval_copy_ref there would decref uninitialized
// bytes. Those slots belong to no frame's own initialization or sweep, so when
// an enclosing activation's register window happens to cover them, the bits are
// left where that frame believes it owns them: its next LDREG into the slot
// decrefs a reference it never took. Repeat that and a shared, engine-lifetime
// object is freed while still reachable.
//
// immutable.js 5.x hit exactly this. Its `o.__proto__ = p` assignments run
// through the prototype-chain builtin-setter path, and three stale slots later
// released `Object.prototype`'s `set __proto__` accessor to refcount zero,
// segfaulting the interpreter with no error message.
//
// All four staging sites (own vs inherited accessor, builtin vs compiled
// setter) are exercised below. The checks after them assert the shared
// accessor pair is still intact, which is what over-releasing destroyed.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// --- compiled setter on an own property ---
var ownSeen = [];
var ownTarget = {};
Object.defineProperty(ownTarget, "x", {
    set: function (v) { ownSeen.push(v); },
    get: function () { return ownSeen.length; }
});
for (var i = 0; i < 200; i++) { ownTarget.x = { n: i }; }
check("ownCompiledSetter", ownSeen.length, 200);

// --- compiled setter inherited from the prototype chain ---
var protoSeen = [];
var base = {};
Object.defineProperty(base, "y", {
    set: function (v) { protoSeen.push(v); },
    get: function () { return protoSeen.length; }
});
function Sub() {}
Sub.prototype = Object.create(base);
for (var j = 0; j < 200; j++) { new Sub().y = { n: j }; }
check("inheritedCompiledSetter", protoSeen.length, 200);

// --- builtin setter reached through the prototype chain: Object.prototype's
//     `__proto__`, invoked from a nested frame with live locals of its own ---
function setProto(o, p) { var a = 1, b = 2, c = 3; o.__proto__ = p; return a + b + c; }
var protoOk = true;
for (var k = 0; k < 200; k++) {
    var t = {};
    setProto(t, { tag: k });
    if (t.tag !== k) { protoOk = false; }
}
check("builtinProtoSetter", protoOk, true);

// --- the shared accessor pair must have survived all of the above ---
var d = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__");
check("protoDescriptorGetter", typeof d.get, "function");
check("protoDescriptorSetter", typeof d.set, "function");
check("protoSetterName", d.set.name, "set __proto__");
check("protoGetterName", d.get.name, "get __proto__");
check("protoGetterCallable", d.get.call({}), Object.prototype);

// --- the receiver reference the staging slot holds must be released, not
//     leaked: a setter that stores its receiver still sees the right object ---
var recvSeen = [];
var recvBase = {};
Object.defineProperty(recvBase, "z", {
    set: function (v) { recvSeen.push(this); }
});
var recvOk = true;
for (var m = 0; m < 100; m++) {
    var inst = Object.create(recvBase);
    inst.z = m;
    if (recvSeen[m] !== inst) { recvOk = false; }
}
check("setterReceiverIdentity", recvOk, true);

// --- a setter that throws unwinds through vm_throw's pop loops, which skip the
//     ordinary register sweep, so they release the staged pair themselves ---
var thrower = {};
Object.defineProperty(thrower, "boom", {
    set: function (v) { throw new Error("boom " + v); }
});
var caught = 0;
for (var n = 0; n < 100; n++) {
    var victim = Object.create(thrower);
    try { victim.boom = n; } catch (e) { caught++; }
}
check("throwingSetterUnwind", caught, 100);

// --- the same, thrown from a frame nested below the setter ---
function rethrows() { throw new Error("nested"); }
var nestedThrower = {};
Object.defineProperty(nestedThrower, "deep", {
    set: function (v) { rethrows(); }
});
var nestedCaught = 0;
for (var q = 0; q < 100; q++) {
    try { Object.create(nestedThrower).deep = q; } catch (e2) { nestedCaught++; }
}
check("nestedThrowingSetterUnwind", nestedCaught, 100);

// The shared accessor pair must still be intact after all that unwinding.
var d2 = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__");
check("protoSetterIntactAfterUnwind", typeof d2.set, "function");

if (failures === 0) {
    print("PASS: setter staging slots are released and cleared");
} else {
    print("FAILED: " + failures + " check(s)");
}
