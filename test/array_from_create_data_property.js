// Array.from stores each element with CreateDataPropertyOrThrow (ES2024
// 23.1.2.1 steps 6.g.ix / 7.e.vi), which is defined in terms of
// O.[[DefineOwnProperty]].
//
// The helper wrote the object's own storage directly instead, so every
// exotic [[DefineOwnProperty]] was bypassed. With a Proxy as the
// constructor's result, no element ever reached the "defineProperty" trap:
// the trap log held only the trailing length write.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function trapLogger() {
    var log = [];
    var p = new Proxy({}, {
        defineProperty: function (t, k, d) { log.push("def:" + String(k)); return Reflect.defineProperty(t, k, d); },
        set: function (t, k, v, r) { log.push("set:" + String(k)); return Reflect.set(t, k, v, r); }
    });
    return { proxy: p, log: log };
}

// --- iterator path: elements must be DEFINED, not set ---
var t1 = trapLogger();
function C1() { return t1.proxy; }
Array.from.call(C1, [1, 2]);
check("iterator path defines each element", t1.log.join(","), "def:0,def:1,set:length,def:length");

// --- array-like path: same requirement ---
var t2 = trapLogger();
function C2() { return t2.proxy; }
Array.from.call(C2, { length: 2, 0: "a", 1: "b" });
check("array-like path defines each element", t2.log.join(","), "def:0,def:1,set:length,def:length");

// --- define semantics: a non-extensible target must throw ---
function CFrozen() { return Object.freeze({}); }
var threw = false;
try { Array.from.call(CFrozen, [1]); } catch (e) { threw = e instanceof TypeError; }
check("non-extensible target throws TypeError", threw, true);

// --- the ordinary paths keep working and keep their values ---
check("from array",      Array.from([1, 2, 3]).join(),        "1,2,3");
check("from Set",        Array.from(new Set([1, 2])).join(),  "1,2");
check("from string",     Array.from("abc").join(),            "a,b,c");
check("from array-like", Array.from({ length: 3, 0: "x", 2: "z" }).join(), "x,,z");
check("from generator",  Array.from(function* () { yield 1; yield 2; }()).join(), "1,2");
check("with mapfn",      Array.from([1, 2], function (x, i) { return x + i; }).join(), "1,3");
check("from empty",      Array.from([]).length,               0);
check("from TypedArray", Array.from(new Uint8Array([1, 2])).join(), "1,2");

// A custom constructor still receives the elements and the length.
function Ctor() { this.tag = "ctor"; }
var made = Array.from.call(Ctor, [7, 8]);
check("custom ctor instance", made instanceof Ctor, true);
check("custom ctor length",   made.length,          2);
check("custom ctor values",   made[0] + "," + made[1], "7,8");

// The iterator is still closed when the mapping function throws.
var closed = false;
var iterable = { [Symbol.iterator]: function () {
    return { next: function () { return { done: false, value: 1 }; },
             return: function () { closed = true; return { done: true }; } };
} };
try { Array.from(iterable, function () { throw new Error("boom"); }); } catch (e) {}
check("iterator closed when mapfn throws", closed, true);

if (failures === 0) { print("array_from_create_data_property: all checks passed"); }
