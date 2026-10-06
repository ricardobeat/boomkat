// Flat array parameters use guarded extraction and publish captured names.

function sumPair([a, b]) { return a + b; }
function readPairLater([a, b]) { return function () { return a + b; }; }
function updatePair([a, b]) { a++; b = 10; return a + b; }
function returnArgument([a, b]) { return arguments[0]; }
function defaultPair([a, b] = [4, 6]) { return a + b; }
function evalPair([a, b]) { return eval("a + b"); }

var pair = [2, 5];
if (sumPair(pair) !== 7) throw new Error("flat array parameter values");
var reader = readPairLater(pair);
if (reader() !== 7) throw new Error("captured parameter bindings");
if (updatePair(pair) !== 13) throw new Error("mutable parameter bindings");
if (returnArgument(pair) !== pair) throw new Error("unmapped arguments retains source array");
if (defaultPair() !== 10) throw new Error("parameter defaults keep their full lowering");
if (evalPair(pair) !== 7) throw new Error("direct eval sees published parameter bindings");

var missingThrew = false;
try {
    sumPair();
} catch (error) {
    missingThrew = error instanceof TypeError;
}
if (!missingThrew) throw new Error("missing array parameter must reject non-iterable undefined");

var iteratorProto = Object.getPrototypeOf([][Symbol.iterator]());
var originalNext = iteratorProto.next;
var nextCalls = 0;
try {
    iteratorProto.next = function () {
        nextCalls++;
        return originalNext.call(this);
    };
    if (sumPair(pair) !== 7 || nextCalls !== 2) {
        throw new Error("patched iterator next must run for each parameter element");
    }
} finally {
    iteratorProto.next = originalNext;
}

var originalReturn = Object.getOwnPropertyDescriptor(iteratorProto, "return");
var closeCalls = 0;
try {
    Object.defineProperty(iteratorProto, "return", {
        configurable: true,
        value: function () { closeCalls++; return {}; }
    });
    if (sumPair(pair) !== 7 || closeCalls !== 1) {
        throw new Error("parameter destructuring must close when iterator return is present");
    }
} finally {
    if (originalReturn) Object.defineProperty(iteratorProto, "return", originalReturn);
    else delete iteratorProto.return;
}

var arrayProto = Array.prototype;
var originalIterator = Object.getOwnPropertyDescriptor(arrayProto, Symbol.iterator);
var iteratorCalls = 0;
try {
    Object.defineProperty(arrayProto, Symbol.iterator, {
        configurable: true,
        writable: true,
        value: function () {
            iteratorCalls++;
            return originalIterator.value.call(this);
        }
    });
    if (sumPair(pair) !== 7 || iteratorCalls !== 1) {
        throw new Error("parameter destructuring must call a patched array iterator");
    }
} finally {
    Object.defineProperty(arrayProto, Symbol.iterator, originalIterator);
}

var order = [];
var customIterable = {};
customIterable[Symbol.iterator] = function () {
    order.push("open");
    var index = 0;
    return {
        next: function () {
            order.push("next");
            if (index === 2) return { done: true };
            return { value: ++index, done: false };
        },
        return: function () {
            order.push("close");
            return {};
        }
    };
};
var mixedObject = {};
Object.defineProperty(mixedObject, "x", {
    get: function () { order.push("x"); return 10; }
});
Object.defineProperty(mixedObject, "y", {
    get: function () { order.push("y"); return 20; }
});
function mixedPattern({ x, y }, [a, b]) {
    order.push("body");
    return x + y + a + b;
}
function readMixedLater({ x, y }, [a, b]) {
    return function () { return x + y + a + b; };
}
var mixedReader = readMixedLater({ x: 1, y: 2 }, [3, 4]);
if (mixedReader() !== 10) {
    throw new Error("mixed fast extraction publishes captured parameter bindings");
}
if (mixedPattern(mixedObject, customIterable) !== 33
    || order.join(",") !== "x,y,open,next,next,close,body") {
    throw new Error("mixed parameter patterns preserve getter and iterator order");
}

order.length = 0;
var sentinel = {};
var throwingObject = {};
Object.defineProperty(throwingObject, "x", {
    get: function () { order.push("x"); return 10; }
});
Object.defineProperty(throwingObject, "y", {
    get: function () { order.push("y-throw"); throw sentinel; }
});
var mixedThrew = false;
try {
    mixedPattern(throwingObject, customIterable);
} catch (error) {
    mixedThrew = error === sentinel;
}
if (!mixedThrew || order.join(",") !== "x,y-throw") {
    throw new Error("a throwing object getter must precede array iterator setup");
}

function manyPairs([a], tag, [b, c, d], [e, f]) {
    return a + tag + b + c + d + e + f;
}
if (manyPairs([1], 2, [3, 4, 5], [6, 7]) !== 28) {
    throw new Error("flat patterns in independent parameter positions");
}
if (manyPairs([1], 2, [3], [6, 7]) === 28) {
    throw new Error("short source must preserve undefined elements");
}
function lexicalTriple(values) {
    const [a, b, c] = values;
    return a + b + c;
}
if (lexicalTriple([1, 2, 3]) !== 6) throw new Error("flat lexical triple");

function laterDefault([a, b], c = a + b) { return c; }
if (laterDefault([4, 5]) !== 9) throw new Error("later default sees initialized pattern");
var tdzThrew = false;
function earlierDefault(c = a, [a, b]) { return c; }
try { earlierDefault(undefined, [4, 5]); }
catch (e) { tdzThrew = e instanceof ReferenceError; }
if (!tdzThrew) throw new Error("earlier default must see pattern TDZ");

order.length = 0;
function computedBefore({ [order.push("key")]: ignored }, [a, b]) {
    return a + b;
}
if (computedBefore({}, customIterable) !== 3
    || order.join(",") !== "key,open,next,next,close") {
    throw new Error("computed parameter key precedes array iteration");
}

var patchedSource = [2, 3];
var preceding = { get x() {
    patchedSource[Symbol.iterator] = customIterable[Symbol.iterator];
    return 1;
} };
order.length = 0;
function mutationBefore({x}, [a, b]) { return x + a + b; }
if (mutationBefore(preceding, patchedSource) !== 4
    || order.join(",") !== "open,next,next,close") {
    throw new Error("earlier getter mutation is checked before fast extraction");
}
print("destructuring_array_param_fast: all checks passed");
