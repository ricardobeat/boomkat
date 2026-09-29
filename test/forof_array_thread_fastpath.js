function fail(message) { throw new Error(message); }

function collectValues(source) {
    var out = [];
    for (const value of source) out.push(value);
    return out;
}

var dense = collectValues([3, 5, 7, 11]);
if (dense.join(",") !== "3,5,7,11") {
    fail("threaded array steps preserve dense numeric values");
}

var mutable = [13, 17, 19];
var mutationValues = [];
for (const value of mutable) {
    mutationValues.push(value);
    if (value === 13) {
        mutable[1] = 23;
        mutable.push(29);
    } else if (value === 23) {
        mutable.length = 2;
    }
}
if (mutationValues.join(",") !== "13,23") {
    fail("each step observes live elements and array length");
}

var grows = [31];
var growthValues = [];
for (const value of grows) {
    growthValues.push(value);
    if (value === 31) grows.push(37);
}
if (growthValues.join(",") !== "31,37") {
    fail("array growth during iteration is observed");
}

var objectValue = { marker: 41 };
var objectValues = collectValues([objectValue, 43]);
if (objectValues[0] !== objectValue || objectValues[1] !== 43) {
    fail("heap-valued elements use the ownership-aware path");
}

var explicitUndefined = collectValues([undefined, 47]);
if (explicitUndefined.length !== 2 || explicitUndefined[0] !== undefined
    || explicitUndefined[1] !== 47) {
    fail("explicit undefined uses the ordinary iterator path");
}

var inheritedProto = Object.create(Array.prototype);
var getterCalls = 0;
Object.defineProperty(inheritedProto, "0", {
    configurable: true,
    get: function () { getterCalls++; return 53; }
});
var inheritedHole = [, 59];
Object.setPrototypeOf(inheritedHole, inheritedProto);
var inheritedValues = collectValues(inheritedHole);
if (getterCalls !== 1 || inheritedValues.join(",") !== "53,59") {
    fail("holes and inherited indexed getters keep iterator semantics");
}

var iteratorProto = Object.getPrototypeOf([0][Symbol.iterator]());
var originalNext = Object.getOwnPropertyDescriptor(iteratorProto, "next");
var nextCalls = 0;
try {
    Object.defineProperty(iteratorProto, "next", {
        configurable: true,
        writable: true,
        value: function () {
            nextCalls++;
            return originalNext.value.call(this);
        }
    });
    var patched = collectValues([61, 67]);
    if (patched.join(",") !== "61,67" || nextCalls !== 3) {
        fail("a patched next method runs for values and completion");
    }
} finally {
    Object.defineProperty(iteratorProto, "next", originalNext);
}

var originalReturn = Object.getOwnPropertyDescriptor(iteratorProto, "return");
var closeCalls = 0;
try {
    Object.defineProperty(iteratorProto, "return", {
        configurable: true,
        writable: true,
        value: function () { closeCalls++; return {}; }
    });
    for (const value of [71, 73, 79]) break;
    try {
        for (const value of [83, 89]) throw value;
    } catch (caught) {
        if (caught !== 83) fail("throw preserves the original completion");
    }
    if (closeCalls !== 2) fail("break and throw close the array iterator");
} finally {
    if (originalReturn) Object.defineProperty(iteratorProto, "return", originalReturn);
    else delete iteratorProto.return;
}

print("forof_array_thread_fastpath: all checks passed");
