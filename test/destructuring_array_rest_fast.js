function fail(message) { throw new Error(message); }

function split(source) {
    const [first, second, ...rest] = source;
    return [first, second, rest];
}

function collect(source) {
    const [...rest] = source;
    return rest;
}

var result = split([3, 5, 7, 11]);
if (result[0] !== 3 || result[1] !== 5
    || result[2].length !== 2 || result[2][0] !== 7 || result[2][1] !== 11) {
    fail("flat lexical rest preserves prefix values and copies the remainder");
}

var empty = split([3, 5]);
if (empty[2].length !== 0) fail("rest is empty after consuming the full source");

var short = split([3]);
if (short[0] !== 3 || short[1] !== undefined || short[2].length !== 0) {
    fail("short iterables bind undefined and an empty rest array");
}

var all = collect([2, 4, 6]);
if (all.length !== 3 || all[0] !== 2 || all[2] !== 6) {
    fail("rest-only pattern collects every source value");
}

var retained = (function () {
    const [first, ...rest] = [13, 17, 19];
    return function () { return first + rest[1]; };
})();
if (retained() !== 32) fail("captured lexical bindings see fast-path values");

var ownIteratorCalls = 0;
var ownIterable = [0, 0, 0];
ownIterable[Symbol.iterator] = function () {
    ownIteratorCalls++;
    var index = 0;
    return {
        next: function () {
            if (index === 3) return { done: true };
            return { value: ++index * 10, done: false };
        }
    };
};
var custom = split(ownIterable);
if (ownIteratorCalls !== 1 || custom[0] !== 10 || custom[1] !== 20
    || custom[2][0] !== 30) {
    fail("an own iterator uses the generic protocol");
}

var iteratorProto = Object.getPrototypeOf([][Symbol.iterator]());
var originalNext = iteratorProto.next;
var nextCalls = 0;
try {
    iteratorProto.next = function () {
        nextCalls++;
        return originalNext.call(this);
    };
    var patchedNext = split([1, 2, 3]);
    if (patchedNext[2][0] !== 3 || nextCalls !== 4) {
        fail("patched iterator next runs for prefix, rest values, and exhaustion");
    }
} finally {
    iteratorProto.next = originalNext;
}

var inherited = [1, , 3];
var inheritedDescriptor = Object.getOwnPropertyDescriptor(Array.prototype, "1");
try {
    Object.defineProperty(Array.prototype, "1", {
        configurable: true,
        get: function () { return 23; }
    });
    var inheritedValues = split(inherited);
    if (inheritedValues[1] !== 23 || inheritedValues[2][0] !== 3) {
        fail("a hole with an inherited getter uses the iterator path");
    }
} finally {
    if (inheritedDescriptor) Object.defineProperty(Array.prototype, "1", inheritedDescriptor);
    else delete Array.prototype["1"];
}

var object = { marker: 29 };
var objectValues = split([1, object, 3]);
if (objectValues[1] !== object || objectValues[2][0] !== 3) {
    fail("heap-valued elements retain their identity on the generic path");
}

var defaulted = (function (source) {
    const [first = 31, ...rest] = source;
    return [first, rest];
})([undefined, 37]);
if (defaulted[0] !== 31 || defaulted[1][0] !== 37) {
    fail("defaults keep iterator semantics");
}

print("destructuring_array_rest_fast: all checks passed");
