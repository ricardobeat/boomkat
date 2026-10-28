// A call inside a hot loop need not end the native run: the tier calls a
// compiled callee through its own entry and keeps going. These cases cover the
// register state the call crosses (the receiver, the arguments, the result, the
// register cache) and the faults that only appear once such a site compiles.
var failures = 0;

function check(label, actual, expected) {
    if (actual !== expected) {
        print("FAIL " + label + ": got " + actual + ", expected " + expected);
        failures++;
    }
}

// A method whose body is too large to expand: the call site stays a call.
function Counter(step) {
    this.step = step;
    this.total = 0;
}
Counter.prototype.add = function (n) {
    var scaled = n * this.step;
    if (scaled > 100) scaled = scaled - 100;
    this.total = this.total + scaled;
    return this.total;
};

function runCounter(n) {
    var counter = new Counter(3);
    var last = 0;
    for (var i = 0; i < n; i++) last = counter.add(i);
    return last;
}

for (var round = 0; round < 120; round++) check("counter", runCounter(40), 1740);

// The result is a string, so the call's value crosses the register cache.
function Name(prefix) { this.prefix = prefix; }
Name.prototype.label = function (n) {
    var text = this.prefix + n;
    return text + "!";
};

function runLabels(n) {
    var name = new Name("item");
    var last = "";
    for (var i = 0; i < n; i++) last = name.label(i);
    return last;
}

for (var round = 0; round < 120; round++) check("label", runLabels(30), "item29!");

// A throw inside the compiled callee becomes the call's throw, so the caller's
// own catcher still sees it and the loop keeps running.
function narrow(n) {
    if (n > 2) throw new Error("too big: " + n);
    return n;
}

function runCatch(n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        try {
            total = total + narrow(i);
        } catch (e) {
            total = total + 10;
        }
    }
    return total;
}

for (var round = 0; round < 120; round++) check("catch", runCatch(6), 33);

// A closure pushed inside a loop: the per-iteration binding, the array append
// and the call to the loop body all meet in one native region.
function makeReaders(n) {
    var readers = [];
    for (let i = 0; i < n; i++) readers.push(() => i);
    return readers;
}

for (var round = 0; round < 120; round++) {
    var readers = makeReaders(4);
    check("readers", readers.map((f) => f()).join(","), "0,1,2,3");
}

// The document.all sentinel is an object that the language treats as falsy.
var dda = __isHTMLDDA();
function sentinel(n) {
    var held = 0;
    for (var i = 0; i < n; i++) if (!dda) held++;
    return held;
}

for (var round = 0; round < 120; round++) check("sentinel", sentinel(5), 5);

if (failures == 0) print("jit_native_call: PASS");
