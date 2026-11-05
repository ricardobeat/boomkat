// Baseline tier: returns, equality, truth tests, negation, bitwise operators on
// doubles, builtin calls, allocation and strings in registers. The output must
// not depend on whether the JIT runs.
var lines = [];
function out(s) { lines.push(String(s)); }
function show(v) {
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "bigint") return v + "n";
    if (typeof v === "symbol") return v.toString();
    if (v === 0 && 1 / v < 0) return "-0";
    if (typeof v === "object" && v !== null) return "[object]";
    if (typeof v === "function") return "[function]";
    return String(v);
}

// --- Returns ---
function plain(x) { return x + 1; }
function noValue() { return; }
function retObj() { return { k: 1 }; }
function retStr(n) { return "s" + n; }
function viaFinally(n) {
    try { if (n > 1) return "try" + n; } finally { if (n === 3) return "finally"; }
    return "end";
}
function Base(v) { this.v = v; }
function BaseObj(v) { this.v = v; return { other: v }; }
function BasePrim(v) { this.v = v; return 42; }
class Derived extends Base {
    constructor(v) { super(v); this.w = v * 2; }
}
class DerivedRet extends Base {
    constructor(v) { super(v); return { replaced: v }; }
}
class DerivedBad extends Base {
    constructor(v) { super(v); return 7; }
}
function argsUser(a, b) { arguments[0] = 9; return a + b; }
function deep(n) { return n === 0 ? 0 : 1 + deep(n - 1); }
(function () {
    var acc = 0;
    for (var i = 0; i < 300; i++) {
        acc += plain(i);
        if (noValue() !== undefined) acc = -1;
        acc += retObj().k + retStr(i).length;
    }
    out("returns " + acc);
    out([viaFinally(1), viaFinally(2), viaFinally(3)].join(","));
    var d = new Derived(4);
    out("derived " + d.v + " " + d.w + " " + (d instanceof Base));
    out("baseobj " + JSON.stringify(new BaseObj(5)));
    out("baseprim " + JSON.stringify(new BasePrim(6)));
    out("derivedret " + JSON.stringify(new DerivedRet(3)));
    try { new DerivedBad(1); out("no throw"); } catch (e) { out("derivedbad " + e.constructor.name); }
    out("args " + argsUser(1, 2));
    out("deep " + deep(500));
})();

// --- Equality across tag pairings ---
var interned = "abc";
var built = ["a", "b", "c"].join("");
var big1 = 10n, big2 = BigInt(10);
var obj1 = {}, obj2 = {};
var sym = Symbol("s");
var values = [0, -0, 1, 1.5, NaN, Infinity, -Infinity, 2 ** 47, -(2 ** 47), 2 ** 53,
    "", "0", "1", interned, built, "abc", true, false, null, undefined,
    big1, big2, 0n, obj1, obj2, sym, [1], function () {}];
function eqs(a, b) { return a == b; }
function neqs(a, b) { return a != b; }
function seqs(a, b) { return a === b; }
function sneqs(a, b) { return a !== b; }
function jeq(a, b) { if (a == b) return 1; return 0; }
function jneq(a, b) { if (a != b) return 1; return 0; }
function jseq(a, b) { if (a === b) return 1; return 0; }
function jsneq(a, b) { if (a !== b) return 1; return 0; }
(function () {
    for (var i = 0; i < values.length; i++) {
        var row = "";
        for (var j = 0; j < values.length; j++) {
            var a = values[i], b = values[j];
            var bits = (eqs(a, b) ? 1 : 0) + (neqs(a, b) ? 2 : 0) + (seqs(a, b) ? 4 : 0)
                + (sneqs(a, b) ? 8 : 0) + jeq(a, b) * 16 + jneq(a, b) * 32
                + jseq(a, b) * 64 + jsneq(a, b) * 128;
            row += bits.toString(16) + " ";
        }
        out("eq " + show(values[i]) + ": " + row);
    }
    // Coercing loose equality calls valueOf.
    var calls = 0;
    var vo = { valueOf: function () { calls++; return 3; } };
    var hits = 0;
    for (var k = 0; k < 50; k++) {
        if (vo == 3) hits++;
        if (3 != vo) hits += 100;
    }
    out("valueOf eq " + hits + " " + calls);
})();

// --- Truth tests and LNOT ---
function truthy(v) { return !v; }
function branch(v) { if (v) return "T"; return "F"; }
(function () {
    var row = "";
    for (var i = 0; i < values.length; i++) row += (truthy(values[i]) ? "1" : "0") + branch(values[i]);
    out("truth " + row);
    var n = 0;
    for (var k = 0; k < 1000; k++) { if (!(k & 1)) n++; if (!"" ) n++; }
    out("lnot loop " + n);
})();

// --- Negation ---
function neg(v) { return -v; }
(function () {
    var cases = [0, -0, 1, -1, 2 ** 47 - 1, -(2 ** 47), 1.5, NaN, Infinity, "3", true, null, undefined, 5n];
    var row = [];
    for (var i = 0; i < cases.length; i++) row.push(show(neg(cases[i])));
    out("neg " + row.join(" "));
    var s = 0;
    for (var k = 0; k < 500; k++) s += -k + -(k * 0.5);
    out("neg loop " + s);
})();

// --- Bitwise operators on doubles ---
function bor(a) { return a | 0; }
function bxor(a, b) { return a ^ b; }
function band(a) { return a & 255; }
function shl(a) { return a << 3; }
function shr(a, b) { return a >> b; }
function ushr(a) { return a >>> 1; }
(function () {
    var cases = [0, -0, 1.9, -1.9, 2147483647.5, 2147483648, -2147483648.7, -2147483649,
        4294967296.5, 1e20, -1e20, NaN, Infinity, -Infinity, 0.5, -0.5, 123456.789, "7.5", true];
    for (var i = 0; i < cases.length; i++) {
        var a = cases[i];
        out("bits " + show(a) + ": " + [bor(a), bxor(a, 3.7), band(a), shl(a), shr(a, 1.2), ushr(a)].join(" "));
    }
    var h = 0;
    for (var k = 0; k < 2000; k++) h = (h * 31 + k * 0.75) | 0;
    out("hash " + h);
})();

// --- Builtin calls, method calls on primitives ---
(function () {
    var acc = 0;
    var arr = [];
    for (var i = 0; i < 200; i++) {
        acc += Math.floor(i / 3) + Math.floor() + Math.floor(i / 7, 99);
        acc += "hello".charCodeAt(i % 5) + "x".charCodeAt();
        arr.push(i, i * 2);
        arr.push();
    }
    out("builtins " + acc + " " + arr.length);
    out("NaN floor " + Math.floor());
    var n = 0;
    for (var j = 0; j < 100; j++) n += (j).toString().length + (1.5).toFixed(1).length + true.toString().length;
    out("primitive methods " + n);
})();

// --- Allocation with holes ---
(function () {
    var total = 0;
    for (var i = 0; i < 300; i++) {
        var o = { a: i, b: "x" + i, c: null };
        var a = [1, , 3, , i];
        var e = [];
        e[5] = i;
        total += o.a + o.b.length + a.length + (1 in a ? 1 : 0) + e.length + (a[1] === undefined ? 1 : 0);
    }
    out("alloc " + total);
})();

// --- Strings through registers across GC ---
(function () {
    var keep = [];
    var s = "";
    for (var i = 0; i < 2000; i++) {
        var t = "p" + i;
        var u = t;
        var v = u + "q";
        s = v;
        if ((i & 63) === 0) {
            keep.push(v);
            if (typeof gc === "function") gc();
            var junk = [];
            for (var k = 0; k < 200; k++) junk.push({ k: k, s: "j" + k });
        }
    }
    out("strings " + s + " " + keep.length + " " + keep[keep.length - 1]);
})();


// --- Builtins that throw, re-dispatch or call back ---
function addOne(x) { return x + 1; }
(function () {
    var caught = 0, sum = 0;
    for (var i = 0; i < 100; i++) {
        try { "x".normalize("bad"); } catch (e) { if (e instanceof RangeError) caught++; }
        try { null.foo(); } catch (e) { caught++; }
        sum += addOne.call(null, i) + addOne.apply(null, [i]);
        sum += [1, 2, 3].map(addOne).reduce(function (a, b) { return a + b; }, 0);
        sum += Math.max(i, 50) + Math.abs(-i) + String.fromCharCode(65 + (i % 26)).length;
    }
    out("builtin edge " + caught + " " + sum);
})();

// --- instanceof, global stores, polymorphic sites, typed arrays ---
var gcount = 0;
function bumpGlobal() { gcount = gcount + 1; }
function A() { this.x = 1; }
function B() { this.y = 2; this.x = 3; }
function C() { this.z = 4; this.w = 5; this.x = 6; }
(function () {
    var objs = [new A(), new B(), new C(), { x: 7 }, { q: 0, x: 8 }, Object.create({ x: 9 })];
    var t = 0, inst = 0;
    for (var i = 0; i < 600; i++) {
        var o = objs[i % objs.length];
        t += o.x;
        o.x = o.x;
        if (o instanceof A) inst++;
        if (o instanceof B) inst += 10;
        if (i instanceof Object) inst = -1;
        bumpGlobal();
    }
    out("poly " + t + " " + inst + " " + gcount);
    try { ({}) instanceof 3; } catch (e) { out("instanceof throws " + e.constructor.name); }
    var f64 = new Float64Array(8), i32 = new Int32Array(8), u8 = new Uint8ClampedArray(8);
    var acc = 0;
    for (var k = 0; k < 400; k++) {
        f64[k & 7] = k * 0.5;
        i32[k & 7] = k * 3;
        u8[k & 7] = k * 7;
        acc += f64[(k + 1) & 7] + i32[(k + 3) & 7] + u8[(k + 5) & 7];
    }
    out("typed " + acc + " " + typeof f64[9]);
})();

for (var li = 0; li < lines.length; li++) print(lines[li]);
print("jit_baseline_misc: " + lines.length + " lines");
