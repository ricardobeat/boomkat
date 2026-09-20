var checks = 0;

function assert(condition, label) {
    checks++;
    if (!condition) throw new Error("compact capture failure: " + label);
}

function makeShared(parameter) {
    var value = 1;
    for (var i = 0; i < 4; i++) {
        value += parameter;
        parameter += i;
    }
    return {
        read: function () { return [parameter, value]; },
        writeParameter: function (next) { parameter = next; return parameter; },
        writeValue: function (next) { value = next; return value; }
    };
}

var shared = makeShared(2);
assert(shared.read()[0] === 8 && shared.read()[1] === 13,
       "defining loop updates captured parameter and var");
assert(shared.writeParameter(20) === 20, "sibling writes captured parameter");
assert(shared.writeValue(30) === 30, "sibling writes captured var");
assert(shared.read()[0] === 20 && shared.read()[1] === 30,
       "sibling reads observe shared writes after return");

function strictFactory(initial) {
    "use strict";
    var value = initial;
    return {
        read: function () { "use strict"; return value; },
        write: function (next) { "use strict"; value = next; }
    };
}

var strictShared = strictFactory(4);
strictShared.write(9);
assert(strictShared.read() === 9, "strict function capture cells");

function heapValueFactory() {
    var held = "first";
    return {
        read: function () { return held; },
        write: function (next) { held = next; }
    };
}

var heapValues = heapValueFactory();
var retainedObject = { marker: "object", nested: { n: 17 } };
heapValues.write("replacement string");
assert(heapValues.read() === "replacement string", "captured string overwrite");
heapValues.write(retainedObject);
var allocationPressure = [];
for (var allocation = 0; allocation < 4000; allocation++) {
    allocationPressure.push({ index: allocation, text: "heap-" + allocation });
}
assert(heapValues.read() === retainedObject, "captured object identity after allocations");
assert(heapValues.read().nested.n === 17, "captured object graph after allocations");

function cycleFactory(id) {
    var cycle;
    function closure() { return cycle; }
    cycle = closure;
    closure.id = id;
    return closure;
}

var survivingCycle = cycleFactory(77);
for (var discarded = 0; discarded < 6000; discarded++) {
    cycleFactory(discarded);
}
for (var cycleNoise = 0; cycleNoise < 3000; cycleNoise++) {
    allocationPressure.push([cycleNoise, { value: cycleNoise }]);
}
assert(survivingCycle() === survivingCycle, "captured closure cycle survives pressure");
assert(survivingCycle.id === 77, "captured closure cycle property");

function evalAncestor(start) {
    var value = start;
    function nestedFactory() {
        return function () { return value; };
    }
    eval("value = value + 5");
    return nestedFactory();
}

var evalDescendant = evalAncestor(10);
assert(evalDescendant() === 15, "descendant capture below direct-eval ancestor");

function withAncestor(scope) {
    var fallback = "outer";
    with (scope) {
        return function nestedFactory() {
            return function () { return [dynamicName, fallback]; };
        };
    }
}

var withDescendant = withAncestor({ dynamicName: "with-value" })();
assert(withDescendant()[0] === "with-value", "descendant retains with binding");
assert(withDescendant()[1] === "outer", "descendant retains outer binding below with");

function CaptureBox(initial) {
    var secret = initial;
    this.read = function () { return secret; };
    this.write = function (next) { secret = next; return this; };
}

var boxA = new CaptureBox({ box: "A" });
var boxB = new CaptureBox({ box: "B" });
assert(boxA.read().box === "A" && boxB.read().box === "B",
       "constructor instances keep independent captures");
assert(boxA.write({ box: "A2" }) === boxA, "constructor closure receiver");
assert(boxA.read().box === "A2" && boxB.read().box === "B",
       "constructor capture write stays instance-local");

function unsupportedOperations(start) {
    var value = start;
    function increment() { return value++; }
    function type() { return typeof value; }
    function middle() {
        return function inner() { return value; };
    }
    return [increment, type, middle()];
}

var unsupported = unsupportedOperations(12);
assert(unsupported[1]() === "number", "typeof captured value");
assert(unsupported[0]() === 12, "post-increment captured result");
assert(unsupported[2]() === 13, "transitive capture observes increment");

var success = "PASS compact capture cells (" + checks + " checks)";
if (typeof print === "function") print(success);
else console.log(success);
