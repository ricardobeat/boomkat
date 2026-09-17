// Integer-Indexed exotic elements are enumerable own properties (ES2024
// §10.4.5.1) served lazily, so they are absent from both the named property
// table and array_part. Every enumeration path has to synthesize them.
var pass = 0, fail = 0;

function ok(cond, name) {
    if (cond) { pass = pass + 1; } else { print("FAIL: " + name); fail = fail + 1; }
}

function eq(a, b, name) { ok(JSON.stringify(a) === JSON.stringify(b), name); }

var ta = new Uint8Array([1, 2]);

eq(Object.keys(ta), ["0", "1"], "Object.keys");
eq(Object.values(ta), [1, 2], "Object.values");
eq(Object.entries(ta), [["0", 1], ["1", 2]], "Object.entries");
eq(Object.assign({}, ta), {"0": 1, "1": 2}, "Object.assign source");
eq({...ta}, {"0": 1, "1": 2}, "object spread");
ok(ta.propertyIsEnumerable("0"), "propertyIsEnumerable on an element");
ok(!ta.propertyIsEnumerable("2"), "propertyIsEnumerable past the end");

// Elements precede named keys, ascending, per OrdinaryOwnPropertyKeys.
var mixed = new Uint8Array([9]);
mixed.x = 5;
eq(Object.entries(mixed), [["0", 9], ["x", 5]], "elements before named keys");

// Object rest applies the exclusion list to synthesized element keys.
var rest = (function (o) { var {0: _first, ...r} = o; return r; })(new Uint8Array([1, 2, 3]));
eq(rest, {"1": 2, "2": 3}, "object rest excludes destructured element");

// A length-tracking view over a resizable buffer reports its current length.
var rab = new ArrayBuffer(4, {maxByteLength: 8});
eq(Object.values(new Uint8Array(rab)), [0, 0, 0, 0], "length-tracking view");

// Other element types round-trip through the same paths.
eq(Object.values(new Float64Array([1.5])), [1.5], "Float64 element");
ok(Object.values(new BigInt64Array([7n]))[0] === 7n, "BigInt64 element");
eq(Object.values(new Uint8Array(0)), [], "empty view");

// A detached view has no valid indices, so every path yields nothing.
var buf = new ArrayBuffer(4);
var detached = new Uint8Array(buf);
buf.transfer();
eq(Object.keys(detached), [], "detached: keys");
eq(Object.values(detached), [], "detached: values");
eq(Object.assign({}, detached), {}, "detached: assign");
eq({...detached}, {}, "detached: spread");
ok(!detached.propertyIsEnumerable("0"), "detached: propertyIsEnumerable");

// String wrapper char indices use the same lazy-key machinery.
eq(Object.values(Object("ab")), ["a", "b"], "String wrapper characters");

print("pass: " + pass + ", fail: " + fail);
if (fail !== 0) { throw new Error(fail + " failures"); }
