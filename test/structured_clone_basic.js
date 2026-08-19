// structuredClone(value) — HTML §2.7.10 (single-realm, single-pass walk).
// Run with the plain runner; structuredClone is registered as a global.

function assert(cond, msg) {
    if (!cond) throw new Error("assert failed: " + msg);
}

function assertEq(a, b, msg) {
    if (a !== b) throw new Error("assertEq failed: " + msg + " (got " + String(a) + " want " + String(b) + ")");
}

// --- Primitives --------------------------------------------------------------

assertEq(structuredClone(undefined), undefined, "clone undefined");
assertEq(structuredClone(null), null, "clone null");
assertEq(structuredClone(true), true, "clone true");
assertEq(structuredClone(false), false, "clone false");
assertEq(structuredClone(0), 0, "clone 0");
assertEq(structuredClone(42), 42, "clone 42");
assertEq(structuredClone(-1.5), -1.5, "clone -1.5");
assertEq(structuredClone("hello"), "hello", "clone 'hello'");

// --- Plain object ------------------------------------------------------------

var src = { a: 1, b: "two", c: true, d: null, e: undefined };
var cl  = structuredClone(src);
assert(cl !== src, "plain object: clone is a new object");
assertEq(cl.a, 1, "plain object: a");
assertEq(cl.b, "two", "plain object: b");
assertEq(cl.c, true, "plain object: c");
assertEq(cl.d, null, "plain object: d");
assertEq(cl.e, undefined, "plain object: e");

// Mutating the clone does not affect the source.
cl.a = 999;
assertEq(src.a, 1, "plain object: source unchanged after clone mutation");

// --- Array -------------------------------------------------------------------

var arr = [1, 2, "three", null];
var carr = structuredClone(arr);
assert(carr !== arr, "array: clone is a new array");
assertEq(carr.length, 4, "array: length");
assertEq(carr[0], 1, "array: [0]");
assertEq(carr[1], 2, "array: [1]");
assertEq(carr[2], "three", "array: [2]");
assertEq(carr[3], null, "array: [3]");
assert(carr instanceof Array, "array: instanceof Array");

// --- Nested structures -------------------------------------------------------

var nested = { list: [1, 2, { inner: { x: "y" } }], scalar: 7 };
var cn = structuredClone(nested);
assertEq(cn.list[2].inner.x, "y", "nested: deep value");
cn.list[2].inner.x = "z";
assertEq(nested.list[2].inner.x, "y", "nested: source unchanged");

// --- Cycles ------------------------------------------------------------------

var cyc = {};
cyc.self = cyc;
cyc.arr = [cyc, cyc];
var ccyc = structuredClone(cyc);
assert(ccyc.self === ccyc, "cycle: self === self");
assert(ccyc.arr[0] === ccyc, "cycle: arr[0] === self");
assert(ccyc.arr[1] === ccyc, "cycle: arr[1] === self");
assert(ccyc.arr[0] === ccyc.arr[1], "cycle: arr entries share identity");

// Shared (non-cycle) references also round-trip as a single clone object.
var shared = { n: 1 };
var src2 = { a: shared, b: shared, c: [shared, shared] };
var c2 = structuredClone(src2);
assert(c2.a === c2.b, "shared: a === b in clone");
assert(c2.c[0] === c2.a, "shared: c[0] === a in clone");
assert(c2.c[0] === c2.c[1], "shared: c[0] === c[1] in clone");

// --- Date --------------------------------------------------------------------

var d = new Date(1700000000000);
var cd = structuredClone(d);
assert(cd instanceof Date, "date: instanceof Date");
assertEq(+cd, +d, "date: same time value");
assert(cd !== d, "date: new instance");
cd.setTime(0);
assertEq(+d, 1700000000000, "date: source unchanged after clone mutation");

// --- RegExp ------------------------------------------------------------------

var re = /abc/gi;
re.lastIndex = 7;
var cre = structuredClone(re);
assert(cre instanceof RegExp, "regexp: instanceof RegExp");
assertEq(cre.source, "abc", "regexp: source");
assertEq(cre.flags, "gi", "regexp: flags");
assertEq(cre.lastIndex, 7, "regexp: lastIndex");
assert(cre !== re, "regexp: new instance");

// --- Map ---------------------------------------------------------------------

var m = new Map();
m.set("a", 1);
m.set(2, "two");
var arrKey = [1, 2];
m.set(arrKey, "value");
var cm = structuredClone(m);
assert(cm instanceof Map, "map: instanceof Map");
assertEq(cm.size, 3, "map: size");
assertEq(cm.get("a"), 1, "map: get('a')");
assertEq(cm.get(2), "two", "map: get(2)");
// The array key is cloned too; use the clone to read it back.
assertEq(cm.get(cm.get(arrKey) === undefined ? cm.get("__nope__") : cm.get(arrKey)), undefined,
    "map: array key is cloned (use original key by identity check below)");
assert(cm.has(arrKey) === false, "map: array key cloned, original is not present");
var arrKeyClone = null;
cm.forEach(function (v, k) { if (Array.isArray(k) && k[0] === 1) arrKeyClone = k; });
assert(arrKeyClone !== null, "map: cloned array key found via iteration");
assertEq(cm.get(arrKeyClone), "value", "map: get(cloned array key)");

// Map with cycles in values (no shared ref preserved, but no crash).
var cm2 = new Map();
var arr2 = [];
cm2.set("arr", arr2);
arr2.push(cm2);
var cmc = structuredClone(cm2);
assert(cmc.get("arr") !== arr2, "map cycle: cloned array is new");
assert(cmc.get("arr")[0] === cmc, "map cycle: array points to clone");

// --- Set ---------------------------------------------------------------------

var s = new Set();
s.add(1);
s.add("x");
s.add(true);
var cs = structuredClone(s);
assert(cs instanceof Set, "set: instanceof Set");
assertEq(cs.size, 3, "set: size");
assert(cs.has(1), "set: has 1");
assert(cs.has("x"), "set: has 'x'");
assert(cs.has(true), "set: has true");

// --- ArrayBuffer / TypedArray / DataView ------------------------------------

var ab = new ArrayBuffer(8);
var u8 = new Uint8Array(ab);
for (var i = 0; i < 8; i++) u8[i] = i + 1;
var cab = structuredClone(ab);
assert(cab instanceof ArrayBuffer, "ab: instanceof ArrayBuffer");
assert(cab !== ab, "ab: new instance");
var cu8 = new Uint8Array(cab);
assertEq(cu8[0], 1, "ab: cloned byte 0");
assertEq(cu8[7], 8, "ab: cloned byte 7");

var ta = new Int32Array([10, 20, 30, 40]);
var cta = structuredClone(ta);
assert(cta instanceof Int32Array, "ta: instanceof Int32Array");
assertEq(cta.length, 4, "ta: length");
assertEq(cta[0], 10, "ta: [0]");
assertEq(cta[3], 40, "ta: [3]");
assert(cta.buffer !== ta.buffer, "ta: clone has its own buffer");

// Detached buffer
var dab = new ArrayBuffer(4);
dab.transfer();
try {
    structuredClone(dab);
    throw new Error("detached buffer: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "detached buffer: DataCloneError");
}

// TypedArray with offset
var full = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]);
var sub = new Uint8Array(full.buffer, 2, 4); // [2, 3, 4, 5]
var csub = structuredClone(sub);
assert(csub instanceof Uint8Array, "sub: instanceof Uint8Array");
assertEq(csub.length, 4, "sub: length");
assertEq(csub[0], 2, "sub: [0]");
assertEq(csub[3], 5, "sub: [3]");
assert(csub.buffer !== full.buffer, "sub: clone has its own buffer");

// Float32Array
var f32 = new Float32Array([1.5, 2.5, 3.5]);
var cf32 = structuredClone(f32);
assert(cf32 instanceof Float32Array, "f32: instanceof Float32Array");
assertEq(cf32[0], 1.5, "f32: [0]");
assertEq(cf32[1], 2.5, "f32: [1]");
assertEq(cf32[2], 3.5, "f32: [2]");

// BigInt64Array
var bi = new BigInt64Array([1n, 2n, 3n]);
var cbi = structuredClone(bi);
assert(cbi instanceof BigInt64Array, "bi: instanceof BigInt64Array");
assertEq(cbi[0], 1n, "bi: [0]");
assertEq(cbi[2], 3n, "bi: [2]");

// DataView
var dv = new DataView(ab);
dv.setInt32(0, 0x12345678, true);
var cdv = structuredClone(dv);
assert(cdv instanceof DataView, "dv: instanceof DataView");
assert(cdv.buffer !== ab, "dv: clone has its own buffer");
assertEq(cdv.getInt32(0, true), 0x12345678, "dv: readback");

// --- Error + subclasses ------------------------------------------------------

var e1 = new Error("base");
e1.cause = "tag";
var ce1 = structuredClone(e1);
assert(ce1 instanceof Error, "Error: instanceof Error");
assertEq(ce1.name, "Error", "Error: name");
assertEq(ce1.message, "base", "Error: message");
assertEq(ce1.cause, "tag", "Error: own enum props carried");
assert(ce1 !== e1, "Error: new instance");

assert(structuredClone(new EvalError("e")) instanceof EvalError, "EvalError prototype");
assert(structuredClone(new RangeError("r")) instanceof RangeError, "RangeError prototype");
assert(structuredClone(new ReferenceError("r")) instanceof ReferenceError, "ReferenceError prototype");
assert(structuredClone(new SyntaxError("s")) instanceof SyntaxError, "SyntaxError prototype");
assert(structuredClone(new TypeError("t")) instanceof TypeError, "TypeError prototype");
assert(structuredClone(new URIError("u")) instanceof URIError, "URIError prototype");
assert(structuredClone(new AggregateError([], "a")) instanceof AggregateError, "AggregateError prototype");

// Error subclass name + message round-trip
var te = structuredClone(new TypeError("boom"));
assertEq(te.name, "TypeError", "TypeError: cloned name");
assertEq(te.message, "boom", "TypeError: cloned message");

// --- Wrappers (Boolean/Number/String) ---------------------------------------
// The boomkat clones wrappers as plain Objects with the source's wrapper
// prototype attached; the [[PrimitiveValue]] is preserved in `extra.prim`,
// which is what the wrapper prototype getters read on the source side. The
// resulting object reads back as a "wrapper" via `instanceof`, but it is not
// a full wrapper (Symbol.toStringTag, valueOf via the prototype accessor, etc.
// are out of scope for this engine).

var wb = structuredClone(Object(true));
assert(typeof wb === "object", "wrapper bool: object type");
assert(wb instanceof Boolean, "wrapper bool: instanceof Boolean");
var wn = structuredClone(Object(42));
assert(typeof wn === "object", "wrapper number: object type");
assert(wn instanceof Number, "wrapper number: instanceof Number");
var ws = structuredClone(Object("hi"));
assert(typeof ws === "object", "wrapper string: object type");
assert(ws instanceof String, "wrapper string: instanceof String");

// --- Rejection cases --------------------------------------------------------

// Function
try {
    structuredClone(function () {});
    throw new Error("function: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "function: DataCloneError");
}

// Symbol
try {
    structuredClone(Symbol("s"));
    throw new Error("symbol: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "symbol: DataCloneError");
}

// Promise
try {
    structuredClone(Promise.resolve(1));
    throw new Error("promise: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "promise: DataCloneError");
}

// WeakMap
try {
    structuredClone(new WeakMap());
    throw new Error("weakmap: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "weakmap: DataCloneError");
}

// WeakSet
try {
    structuredClone(new WeakSet());
    throw new Error("weakset: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "weakset: DataCloneError");
}

// Proxy
try {
    structuredClone(new Proxy({}, {}));
    throw new Error("proxy: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "proxy: DataCloneError");
}

// transfer option (rejected as DataCloneError)
try {
    structuredClone({}, { transfer: [new ArrayBuffer(1)] });
    throw new Error("transfer: should have thrown");
} catch (e) {
    assertEq(e.name, "DataCloneError", "transfer: DataCloneError");
}

// --- Arity check -------------------------------------------------------------

assertEq(structuredClone.length, 1, "structuredClone.length === 1");

// --- Arity error: too few args ----------------------------------------------

try {
    structuredClone();
    throw new Error("arity: should have thrown");
} catch (e) {
    assertEq(e.name, "TypeError", "arity: TypeError");
}

print("structuredClone: all assertions passed");