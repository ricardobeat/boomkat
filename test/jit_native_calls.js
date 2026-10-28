function nativeCheck(value, expected) {
    if (!Object.is(value, expected)) throw new Error('native call: ' + value + ' != ' + expected);
}
function jitNativeStep(n) {
    this.calls++;
    var value = n;
    for (var i = 0; i < 4; i++) value += i;
    return value + this.payload;
}
function jitNativeDrive(object, count) {
    var result = 0;
    for (var i = 0; i < count; i++) result += object.step(i);
    return result;
}
var nativeObject = { calls: 0, payload: 1, step: jitNativeStep };
nativeCheck(jitNativeDrive(nativeObject, 400), 82600);
nativeCheck(nativeObject.calls, 400);

// A coercing ADD escapes after the store in the callee. Neither the call nor
// its store may be replayed, and the interpreter must see every live frame.
var nativeConversions = 0;
nativeObject.payload = { valueOf: function () { nativeConversions++; return 3; } };
nativeCheck(jitNativeDrive(nativeObject, 40), 1140);
nativeCheck(nativeObject.calls, 440);
nativeCheck(nativeConversions, 40);

var nativeGetterCalls = 0;
Object.defineProperty(nativeObject, 'payload', {
    configurable: true,
    get: function () { nativeGetterCalls++; throw new Error('native getter'); }
});
var nativeFinally = 0;
try { jitNativeDrive(nativeObject, 10); throw new Error('missing exception'); }
catch (e) { nativeCheck(e.message, 'native getter'); }
finally { nativeFinally++; }
nativeCheck(nativeObject.calls, 441);
nativeCheck(nativeGetterCalls, 1);
nativeCheck(nativeFinally, 1);

// Return a counted value after warming a call graph that returned numbers.
Object.defineProperty(nativeObject, 'payload', { value: 'result', writable: true });
nativeCheck(nativeObject.step(2), '8result');
nativeCheck(nativeObject.calls, 442);

function jitNativeRecurse(n) {
    if (n <= 0) return 1;
    return this.recurse(n - 1) + 1;
}
var nativeRecursive = { recurse: jitNativeRecurse };
for (var i = 0; i < 60; i++) nativeCheck(nativeRecursive.recurse(150), 151);

// Nested inline returns must write into the outer inline frame's window.
function jitNativeCollectionSize() { return this.elements.length; }
function jitNativePlanSize() { return this.collection.size(); }
function jitNativeSizes(plan) {
    var total = 0;
    for (var i = 0; i < 200; i++) total += plan.size();
    return total;
}
var nativePlan = { collection: { elements: [1, 2, 3], size: jitNativeCollectionSize }, size: jitNativePlanSize };
for (var i = 0; i < 50; i++) nativeCheck(jitNativeSizes(nativePlan), 600);
nativePlan.collection.elements.push(4);
nativeCheck(jitNativeSizes(nativePlan), 800);
// Callee preparation must leave all arguments intact when arity or closure
// requirements send a call to the interpreter.
function nativeArity(a, b) {
    var n = 0;
    for (var i = 0; i < 3; i++) n += i;
    return a + b + n;
}
var nativeArityObject = { run: nativeArity };
for (var i = 0; i < 200; i++) nativeCheck(nativeArityObject.run(2, 3), 8);
nativeCheck(nativeArityObject.run(2), NaN);
nativeCheck(nativeArityObject.run(2, 3, 'extra'), 8);
function makeNativeClosure(value) {
    return function (n) {
        for (var i = 0; i < 3; i++) n += value;
        return n;
    };
}
var nativeClosureA = { run: makeNativeClosure(2) };
var nativeClosureB = { run: makeNativeClosure(7) };
for (var i = 0; i < 200; i++) {
    nativeCheck(nativeClosureA.run(1), 7);
    nativeCheck(nativeClosureB.run(1), 22);
}
console.log('JIT native calls: PASS');
