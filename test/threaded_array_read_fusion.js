// The threaded LDINT + GETPROP path must preserve generic property behavior.

function fail(message) { throw new Error(message); }

var arrayProto = Array.prototype;
var oldIndexZero = Object.getOwnPropertyDescriptor(arrayProto, "0");
var getterCalls = 0;
try {
    Object.defineProperty(arrayProto, "0", {
        configurable: true,
        get: function () { getterCalls++; return 42; }
    });
    var hole = [];
    if (hole[0] !== 42 || getterCalls !== 1) {
        fail("array holes still consult inherited getters");
    }
    var explicitUndefined = [undefined];
    if (explicitUndefined[0] !== undefined || getterCalls !== 1) {
        fail("explicit undefined still shadows inherited getters");
    }
} finally {
    if (oldIndexZero) Object.defineProperty(arrayProto, "0", oldIndexZero);
    else delete arrayProto[0];
}

var keyConversions = 0;
var objectKey = {
    toString: function () { keyConversions++; return "value"; }
};
var object = { value: 17 };
if (object[objectKey] !== 17 || keyConversions !== 1) {
    fail("object property keys still run ToPropertyKey exactly once");
}

var heapValue = { marker: 29 };
var heapValues = [heapValue];
if (heapValues[0] !== heapValue || heapValues[0].marker !== 29) {
    fail("heap-valued array reads retain ordinary ownership handling");
}
var stringValues = ["kept"];
if (stringValues[0] !== "kept") {
    fail("string-valued array reads retain ordinary ownership handling");
}

var indexed = [10];
function clearLength() {
    indexed.length = 0;
    return 1;
}
indexed[0] += clearLength();
if (indexed.length !== 1 || indexed[0] !== 11) {
    fail("compound assignment uses the saved numeric key after its RHS");
}

print("threaded_array_read_fusion: all checks passed");
