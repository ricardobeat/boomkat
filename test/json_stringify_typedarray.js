// JSON.stringify on an integer-indexed exotic object.
//
// SerializeJSONObject uses EnumerableOwnPropertyNames, whose key source for a
// TypedArray is the canonical numeric indices served by the exotic handler, not
// the named property table. Walking only the property table serialized every
// typed array as "{}". DataView and ArrayBuffer are NOT integer-indexed exotics
// and must keep serializing as "{}".
//
// Runs unmodified under node; counts must match.
var failures = 0;
function check(cond, msg) {
    if (!cond) {
        failures++;
        print("FAIL: " + msg);
    }
}
function eq(actual, expected, msg) {
    check(actual === expected, msg + " (got " + actual + ", want " + expected + ")");
}

var numericKinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
                    Int32Array, Uint32Array, Float32Array, Float64Array];

// --- Indices are own enumerable keys for every numeric kind ---
for (var i = 0; i < numericKinds.length; i++) {
    var X = numericKinds[i];
    var t = new X(3);
    t[0] = 1; t[1] = 2; t[2] = 3;
    eq(JSON.stringify(t), '{"0":1,"1":2,"2":3}', X.name + " serializes its indices");
    eq(JSON.stringify(new X(0)), "{}", X.name + " empty is {}");
}

// --- Length 1 and a longer array (key list is not capped) ---
eq(JSON.stringify(new Int32Array([7])), '{"0":7}', "length 1");
var big = new Int32Array(1000);
for (var i = 0; i < 1000; i++) big[i] = i;
var bigStr = JSON.stringify(big);
eq(bigStr.slice(0, 18), '{"0":0,"1":1,"2":2', "length 1000 head");
eq(bigStr.slice(-11), ',"999":999}', "length 1000 tail");
eq(Object.keys(JSON.parse(bigStr)).length, 1000, "length 1000 key count");

// --- Extra named own properties follow the indices ---
var named = new Int16Array([7, 8]);
named.foo = "bar";
eq(JSON.stringify(named), '{"0":7,"1":8,"foo":"bar"}', "indices precede named props");

// --- A non-enumerable named property is still omitted ---
var hidden = new Int8Array([1]);
Object.defineProperty(hidden, "secret", { value: 9, enumerable: false });
eq(JSON.stringify(hidden), '{"0":1}', "non-enumerable named prop omitted");

// --- toJSON wins over the index walk ---
var tj = new Int32Array([1, 2]);
tj.toJSON = function () { return "TJ"; };
eq(JSON.stringify(tj), '"TJ"', "toJSON takes precedence");

// --- Nested in an object and in an array ---
eq(JSON.stringify({ w: new Uint8Array([1, 2]) }), '{"w":{"0":1,"1":2}}', "nested in object");
eq(JSON.stringify([new Uint8Array([1, 2])]), '[{"0":1,"1":2}]', "nested in array");

// --- Replacer function sees each index ---
var seen = [];
JSON.stringify(new Int32Array([4, 5]), function (k, v) { seen.push(k); return v; });
eq(seen.join(","), ",0,1", "replacer function visits every index");
eq(JSON.stringify(new Int32Array([4, 5]), function (k, v) {
    return typeof v === "number" ? v * 10 : v;
}), '{"0":40,"1":50}', "replacer function transforms values");

// --- Replacer array filters indices ---
eq(JSON.stringify(new Int32Array([1, 2, 3]), ["0", "2"]), '{"0":1,"2":3}', "replacer array");

// --- Space argument ---
eq(JSON.stringify(new Int32Array([1, 2]), null, 2), '{\n  "0": 1,\n  "1": 2\n}', "space argument");

// --- Detached buffer contributes no indices ---
var det = new Int32Array([1, 2, 3]);
if (typeof det.buffer.transfer === "function") {
    det.buffer.transfer();
    eq(JSON.stringify(det), "{}", "detached buffer is {}");
}

// --- Round-trip gives a plain object, not a typed array ---
var rt = JSON.parse(JSON.stringify(new Float64Array([1, 2, 3])));
eq(Object.prototype.toString.call(rt), "[object Object]", "round-trip is a plain object");
eq(JSON.stringify(rt), '{"0":1,"1":2,"2":3}', "round-trip re-serializes identically");

// --- BigInt-backed arrays throw (BigInt is not JSON-serializable) ---
var bigKinds = [BigInt64Array, BigUint64Array];
for (var i = 0; i < bigKinds.length; i++) {
    var B = bigKinds[i];
    eq(JSON.stringify(new B(0)), "{}", B.name + " empty is {} (no element to reach)");
    var threw = false;
    try { JSON.stringify(new B([1n])); } catch (e) { threw = e instanceof TypeError; }
    check(threw, B.name + " with an element throws TypeError");
}

// --- NOT integer-indexed exotics: these must stay {} ---
eq(JSON.stringify(new DataView(new ArrayBuffer(8))), "{}", "DataView is {}");
eq(JSON.stringify(new ArrayBuffer(8)), "{}", "ArrayBuffer is {}");
eq(JSON.stringify({ d: new DataView(new ArrayBuffer(4)) }), '{"d":{}}', "nested DataView is {}");

// --- Plain objects and arrays are unaffected ---
eq(JSON.stringify({}), "{}", "empty object still {}");
eq(JSON.stringify({ b: 1, a: 2 }), '{"b":1,"a":2}', "insertion order preserved");
eq(JSON.stringify({ 2: "x", 0: "y" }), '{"0":"y","2":"x"}', "integer keys ascend");
eq(JSON.stringify([1, 2]), "[1,2]", "array unaffected");
// A String wrapper is unwrapped to its primitive by SerializeJSONProperty
// before the object walk, so it never reaches the key collector.
eq(JSON.stringify(new String("ab")), '"ab"', "String wrapper unwraps to a primitive");

if (failures === 0) {
    print("PASS");
} else {
    print("FAILURES: " + failures);
}
