function fail(message) { throw new Error(message); }

function collect(source) {
    var out = "";
    for (const character of source) out += character;
    return out;
}

var mixed = "a\0a\u00e9\u{1f600}b\0z";
if (collect(mixed) !== mixed) {
    fail("ASCII cache steps preserve NUL and Unicode fallback values");
}

var iteratorProto = Object.getPrototypeOf("ab"[Symbol.iterator]());
var originalNext = Object.getOwnPropertyDescriptor(iteratorProto, "next");
var patchedCalls = 0;
try {
    Object.defineProperty(iteratorProto, "next", {
        configurable: true,
        writable: true,
        value: function () {
            patchedCalls++;
            return originalNext.value.call(this);
        }
    });
    if (collect("abca") !== "abca" || patchedCalls !== 5) {
        fail("a patched String Iterator next method remains observable");
    }
} finally {
    Object.defineProperty(iteratorProto, "next", originalNext);
}

var capturedNextCalls = 0;
var changedNext = function () {
    capturedNextCalls++;
    return { value: "!", done: true };
};
var captured = "";
try {
    for (const character of "abca") {
        captured += character;
        if (character === "a") {
            Object.defineProperty(iteratorProto, "next", {
                configurable: true,
                writable: true,
                value: changedNext
            });
        }
    }
    if (captured !== "abca" || capturedNextCalls !== 0) {
        fail("the captured built-in next stays active after prototype mutation");
    }
} finally {
    Object.defineProperty(iteratorProto, "next", originalNext);
}

print("threaded_string_iterator_ascii: all checks passed");
