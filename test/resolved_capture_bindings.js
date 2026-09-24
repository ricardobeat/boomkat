var checks = 0;

function assert(condition, label) {
    checks++;
    if (!condition) throw new Error("capture binding failure: " + label);
}

function makeShared(start) {
    var value = start;
    return {
        read: function () { return value; },
        add: function (amount) { value += amount; return value; }
    };
}

var shared = makeShared(10);
assert(shared.read() === 10, "initial sibling read");
assert(shared.add(5) === 15, "sibling write result");
assert(shared.read() === 15, "sibling observes write");

var independentA = makeShared(1);
var independentB = makeShared(100);
independentA.add(2);
independentB.add(20);
assert(independentA.read() === 3, "first factory instance");
assert(independentB.read() === 120, "second factory instance");

function makeTransitive(value) {
    function middle() {
        return function inner(delta) {
            value += delta;
            return value;
        };
    }
    return middle();
}

var transitive = makeTransitive(7);
assert(transitive(4) === 11, "transitive nested capture");
assert(transitive(1) === 12, "transitive capture survives return");

function makeConstWriter() {
    const fixed = 9;
    return function () { fixed = 10; };
}

var constThrew = false;
try {
    makeConstWriter()();
} catch (error) {
    constThrew = error && error.name === "TypeError";
}
assert(constThrew, "captured const assignment throws");

function checkTdzCapture() {
    function read() { return pending; }
    var threw = false;
    try {
        read();
    } catch (error) {
        threw = error && error.name === "ReferenceError";
    }
    let pending = 42;
    return threw && read() === 42;
}

assert(checkTdzCapture(), "TDZ capture before initialization");

var letClosures = [];
for (let i = 0; i < 3; i++) {
    letClosures.push(function () { return i; });
}
assert(letClosures[0]() === 0, "let loop first iteration");
assert(letClosures[1]() === 1, "let loop second iteration");
assert(letClosures[2]() === 2, "let loop third iteration");

var varClosures = [];
for (var j = 0; j < 3; j++) {
    varClosures.push(function () { return j; });
}
assert(varClosures[0]() === 3, "var loop first closure shares binding");
assert(varClosures[2]() === 3, "var loop last closure shares binding");

function makeShadowed() {
    let name = "outer";
    function outerRead() { return name; }
    var innerRead;
    {
        let name = "inner";
        innerRead = function () { return name; };
    }
    return [outerRead, innerRead];
}

var shadowed = makeShadowed();
assert(shadowed[0]() === "outer", "outer shadowed binding");
assert(shadowed[1]() === "inner", "inner shadowed binding");

function namedExpressionCapture() {
    var self = 7;
    return function self() { return self; };
}
var namedSelf = namedExpressionCapture();
assert(namedSelf() === namedSelf, "named expression self binding");

function captureCatch() {
    try {
        throw { code: 17 };
    } catch (caught) {
        return function () { return caught; };
    }
}

var caughtReader = captureCatch();
assert(caughtReader().code === 17, "catch binding survives return");

function evalCapture() {
    var mutable = 3;
    function read() { return mutable; }
    eval("mutable = 8");
    var shadowValue = eval("let mutable = 99; mutable");
    return [read, shadowValue];
}

var evaluated = evalCapture();
assert(evaluated[0]() === 8, "direct eval mutates captured binding");
assert(evaluated[1] === 99, "direct eval lexical shadow value");
assert(evaluated[0]() === 8, "eval shadow leaves captured binding intact");

function retainObject() {
    var object = { marker: "kept", nested: { n: 23 } };
    return function () { return object; };
}

var retained = retainObject();
var allocationNoise = [];
for (var k = 0; k < 2000; k++) {
    allocationNoise.push({ index: k, text: "allocation-" + k });
}
assert(retained().marker === "kept", "captured object survives allocations");
assert(retained().nested.n === 23, "captured nested object survives allocations");

// The parent's whole source contains direct eval even though the closures are
// created first. Capture lowering must retain the dynamic binding behavior.
function lateEvalCaptures() {
    var value = { n: 1 };
    var effects = 0;
    function read() { return value; }
    function assign(next) {
        value = (effects++, next);
        return value;
    }
    var before = read();
    eval("value = { n: 7 }");
    return [before, read, assign, function () { return effects; }];
}

var lateEval = lateEvalCaptures();
assert(lateEval[0].n === 1, "closure created before later eval initial value");
assert(lateEval[1]().n === 7, "later direct eval mutates captured binding");
var assignedObject = { n: 11 };
assert(lateEval[2](assignedObject) === assignedObject,
       "captured assignment keeps RHS value");
assert(lateEval[3]() === 1, "captured assignment evaluates RHS effects once");

function capturedConstOrdering() {
    const fixed = 1;
    var effects = 0;
    function write() { fixed = (effects++, 2); }
    var errorName = "";
    try { write(); } catch (error) { errorName = error.name; }
    return [effects, errorName, fixed];
}

var constOrdering = capturedConstOrdering();
assert(constOrdering[0] === 1, "captured const evaluates RHS before failure");
assert(constOrdering[1] === "TypeError", "captured const failure type");
assert(constOrdering[2] === 1, "captured const remains unchanged");

function capturedTdzOrdering() {
    var effects = 0;
    function write(next) { pending = (effects++, next); }
    var errorName = "";
    try { write(5); } catch (error) { errorName = error.name; }
    let pending = 3;
    write(8);
    return [effects, errorName, pending];
}

var tdzOrdering = capturedTdzOrdering();
assert(tdzOrdering[0] === 2, "captured TDZ assignment RHS ordering");
assert(tdzOrdering[1] === "ReferenceError", "captured TDZ failure type");
assert(tdzOrdering[2] === 8, "captured assignment works after initialization");

var computedKeyCalls = 0;
function computedMethodKey() {
    computedKeyCalls++;
    return "makeReader";
}

class CaptureBase {
    describe() { return "base"; }
}

class CaptureDerived extends CaptureBase {
    constructor(suffix) {
        super();
        this.suffix = suffix;
    }

    [computedMethodKey()]() {
        return () => super.describe() + this.suffix;
    }
}

var superReader = new CaptureDerived("-derived").makeReader();
assert(computedKeyCalls === 1, "computed class method key evaluated once");
assert(superReader() === "base-derived", "escaping arrow retains super binding");

function resizedBindingEnvironment() {
    var capturedObject = { marker: "resized", nested: { value: 71 } };
    function read() { return capturedObject; }
    var v00 = 0, v01 = 1, v02 = 2, v03 = 3, v04 = 4;
    var v05 = 5, v06 = 6, v07 = 7, v08 = 8, v09 = 9;
    var v10 = 10, v11 = 11, v12 = 12, v13 = 13, v14 = 14;
    var v15 = 15, v16 = 16, v17 = 17, v18 = 18, v19 = 19;
    var v20 = 20, v21 = 21, v22 = 22, v23 = 23, v24 = 24;
    var v25 = 25, v26 = 26, v27 = 27, v28 = 28, v29 = 29;
    var v30 = 30, v31 = 31, v32 = 32, v33 = 33, v34 = 34;
    var v35 = 35, v36 = 36, v37 = 37, v38 = 38, v39 = 39;
    // Keep the declarations live without involving the captured object.
    if (v00 + v05 + v10 + v15 + v20 + v25 + v30 + v35 !== 140) {
        throw new Error("ordinary binding setup");
    }
    return read;
}

var resizedReader = resizedBindingEnvironment();
for (var resizeNoise = 0; resizeNoise < 2000; resizeNoise++) {
    allocationNoise.push({ resizeNoise: resizeNoise });
}
assert(resizedReader().marker === "resized", "capture survives binding-array resizing");
assert(resizedReader().nested.value === 71, "resized binding retains object graph");

var success = "PASS resolved capture bindings (" + checks + " checks)";
if (typeof print === "function") print(success);
else console.log(success);
