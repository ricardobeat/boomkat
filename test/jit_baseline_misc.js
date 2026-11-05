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

// --- Hot loops entered from the interpreter ---
(function () {
    // Called once: the loop switches to native code mid-run.
    function once(n) {
        var s = 0, o = { k: 1 }, str = "";
        for (var i = 0; i < n; i++) {
            s += i * o.k;
            if ((i & 1023) === 0) str += i % 7;
            if (i === 5000) o = { k: 2 };
        }
        return s + " " + str;
    }
    out("once " + once(20000));
    // A loop whose body throws and catches across the switch.
    function catcher(n) {
        var caught = 0;
        for (var i = 0; i < n; i++) {
            try { if (i % 997 === 0) throw new Error("e" + i); } catch (e) { caught++; }
        }
        return caught;
    }
    out("catcher " + catcher(10000));
    // Nested loops and a labelled continue that crosses a finally.
    function nested() {
        var t = 0;
        outer: for (var i = 0; i < 60; i++) {
            for (var j = 0; j < 60; j++) {
                try { if (j === i) continue outer; t += j; } finally { t ^= 1; }
            }
        }
        return t;
    }
    out("nested " + nested());
})();

// --- Generators ---
(function () {
    function* count(n) { for (var i = 0; i < n; i++) yield i; return "done"; }
    var sum = 0, last;
    var g = count(3000);
    for (;;) { var r = g.next(); if (r.done) { last = r.value; break; } sum += r.value; }
    out("gen " + sum + " " + last);
    function* inner() { var x = yield 1; out("inner got " + x); try { yield 2; } finally { out("inner finally"); } }
    function* outer() { var r = yield* inner(); yield 3; return r; }
    var o = outer();
    out(JSON.stringify([o.next(), o.next("a"), o.return(9), o.next()]));
    function* thrower() { try { yield 1; } catch (e) { yield "caught " + e; } }
    var t = thrower(); t.next();
    out(JSON.stringify(t.throw("x")) + " " + JSON.stringify(t.next()));
    function* hot() {
        var acc = 0;
        for (var i = 0; i < 5000; i++) { acc += i; if (i % 1000 === 0) yield acc; }
        return acc;
    }
    out("hot " + Array.from(hot()).join(","));
    function* fib() { var a = 0, b = 1; for (;;) { yield a; var c = a + b; a = b; b = c; } }
    var fs = []; for (var v of fib()) { if (v > 1000) break; fs.push(v); }
    out("fib " + fs.join(" "));
    var spread = [...count(5)];
    out("spread " + spread);
    function* recur(n) { if (n > 0) { yield n; yield* recur(n - 1); } }
    out("recur " + [...recur(6)]);
    class C { *[Symbol.iterator]() { yield* [1, 2, 3]; } }
    out("class gen " + [...new C()]);
})();

// --- with ---
(function () {
    var obj = { a: 1, b: 2 };
    function useWith(n) {
        var t = 0;
        with (obj) {
            for (var i = 0; i < n; i++) { t += a + b; if (i === 500) b = 10; }
        }
        return t;
    }
    out("with " + useWith(3000) + " " + obj.b);
    function shadow(o) { var a = "outer"; with (o) { return a; } }
    out("shadow " + shadow({ a: "inner" }) + " " + shadow({}));
    function withThrow() {
        try { with ({ x: 1 }) { throw x + 1; } } catch (e) { return "with threw " + e; }
    }
    out(withThrow());
    var scoped = { [Symbol.unscopables]: { hidden: true }, hidden: "no", seen: "yes" };
    function unscop() { var hidden = "local"; with (scoped) { return hidden + " " + seen; } }
    out("unscopables " + unscop());
})();

// --- eval top level with a hot loop ---
out("eval " + eval("var es = 0; for (var ei = 0; ei < 5000; ei++) es += ei & 15; es"));
out("indirect eval " + (0, eval)("var ies = ''; for (var k = 0; k < 3000; k++) if (k % 600 === 0) ies += k; ies"));
(function () {
    "use strict";
    out("strict eval " + eval("let s = 1; for (let i = 0; i < 4000; i++) s = (s * 3) % 1009; s"));
})();

// --- WIDE operands: more than 256 registers and constants ---
(function () {
    var src = "var t = 0;";
    for (var i = 0; i < 300; i++) src += "var v" + i + " = " + (i + 0.5) + ";";
    src += "for (var j = 0; j < 2000; j++) { t = t + v299 - v298 + (j & 3); if (v299 < v1) t = -1; }";
    src += "return t + ' ' + (v150 * 2) + ' ' + (v299 === v299);";
    var f = new Function(src);
    out("wide " + f() + " " + f());
    var src2 = "var a = [];";
    for (var i = 0; i < 280; i++) src2 += "var w" + i + " = 's" + i + "';";
    src2 += "for (var j = 0; j < 1000; j++) { if (w279 === 's279') a.length = j; w0 = j + 1; w279 = w279; }";
    src2 += "return a.length + w0 + w140;";
    out("wide2 " + new Function(src2)());
})();

// --- Async functions ---
// --- Construct and apply calls from native code ---
(function () {
    function P(x) { this.x = x; }
    P.prototype.get = function () { return this.x; };
    function PObj(x) { this.x = x; return { y: x }; }
    function PPrim(x) { this.x = x; return 7; }
    function PNt() { this.nt = new.target === PNt; }
    function PThrow(x) { if (x === 3) throw new Error("ctor " + x); this.x = x; }
    function Simple(a, b) { this.a = a; this.b = b; }
    class B { constructor(v) { this.v = v; } }
    class D extends B { constructor(v) { super(v + 1); this.w = new.target === D; } }
    var Klass = function () { this.initialize.apply(this, arguments); };
    Klass.prototype.initialize = function (a, b, c) { this.sum = a + (b || 0) + (c || 0); this.n = arguments.length; };
    function fwd() { return target.apply(null, arguments); }
    function target(a, b) { return (a | 0) * 10 + (b | 0) + arguments.length * 100; }
    function fwdThis() { return getThis.apply(this, arguments); }
    function getThis() { return this === undefined ? "u" : typeof this; }
    var parts = [];
    for (var i = 0; i < 6; i++) {
        parts.push(new P(i).get(), new PObj(i).y, new PObj(i).x, new PPrim(i).x, new PNt().nt,
                   new D(i).v, new D(i).w, new Simple(i, "s").b, new Klass(i, 2).sum, new Klass(i).n,
                   new Klass(i, 1, 1).sum, fwd(i, 2), fwd(i), fwd(), fwdThis.call(i, 1), fwdThis.call({}));
        try { new PThrow(i); parts.push("ok"); } catch (e) { parts.push(e.message); }
    }
    out("construct " + parts.join(","));
    var al = { length: 3, 0: 1, 1: 2, 2: 3 };
    var ap = [];
    for (var i = 0; i < 4; i++) ap.push(target.apply(null, al), target.apply(null, [i]), Math.max.apply(Math, [i, 5, 2]));
    out("apply " + ap.join(","));
    // Method calls on primitives and through getters.
    String.prototype.twice = function () { return this + this; };
    Number.prototype.inc = function () { return this + 1; };
    var go = { get f() { return function (z) { return z * 2; }; } };
    var mp = [];
    for (var i = 0; i < 5; i++) mp.push("ab".twice(), (i).inc(), true.toString(), go.f(i), "xyz".charAt(i));
    out("prim methods " + mp.join(","));
    delete String.prototype.twice; delete Number.prototype.inc;
    // Tail calls in strict code.
    var tc = (function () {
        "use strict";
        function down(n, acc) { if (n === 0) return acc; return down(n - 1, acc + 1); }
        function even(n) { return n === 0 ? true : odd(n - 1); }
        function odd(n) { return n === 0 ? false : even(n - 1); }
        return down(20000, 0) + " " + even(10001);
    })();
    out("tail " + tc);
    // Literals with spread, holes and computed keys.
    var lp = [];
    for (var i = 0; i < 4; i++) {
        var k = "k" + i;
        var o = { a: i, [k]: i * 2, ...{ s: i }, b: "x" + i, c: null, d: { e: i } };
        var arr = [i, , i + 1, ...[7, 8], , "s" + i];
        lp.push(JSON.stringify(o), arr.length, 1 in arr, arr[4], JSON.stringify(arr));
    }
    out("literals " + lp.join(" "));
})();

// --- Typed-array elements ---
(function () {
    var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
                 Int32Array, Uint32Array, Float32Array, Float64Array];
    if (typeof Float16Array === "function") kinds.push(Float16Array);
    var vals = [0, -0, 1, -1, 127, 128, 255, 256, -129, 32767, 32768, 65535, 65536,
                2147483647, 2147483648, -2147483648, 4294967295, 4294967296,
                1.5, -1.5, 2.5, 0.1, NaN, Infinity, -Infinity, 1e20, -1e-320,
                "7", true, null, undefined, { valueOf: function () { return 9; } }];
    function put(a, i, v) { a[i] = v; }
    function get(a, i) { return a[i]; }
    for (var k = 0; k < kinds.length; k++) {
        var a = new kinds[k](8);
        var parts = [];
        for (var r = 0; r < 3; r++) {
            for (var j = 0; j < vals.length; j++) {
                put(a, j & 7, vals[j]);
                parts.push(show(get(a, j & 7)));
            }
        }
        parts.push(show(get(a, 8)), show(get(a, -1)), show(get(a, 1.5)), show(get(a, "1")));
        put(a, 8, 5); put(a, -1, 5); put(a, 1.5, 5); put(a, "2", 6);
        parts.push(show(get(a, 2)), show(a[-1]), show(a[1.5]), String(a.length));
        out(kinds[k].name + " " + parts.join(" "));
    }
    // HEAP32[i >> 2] with views over one buffer at offsets.
    var buf = new ArrayBuffer(64);
    var h32 = new Int32Array(buf), h8 = new Uint8Array(buf), f64 = new Float64Array(buf, 8, 4);
    var sum = 0;
    for (var i = 0; i < 2000; i++) {
        h32[(i * 4 & 63) >> 2] = i * 7919 | 0;
        sum = (sum + h8[i & 63] + h32[(i & 15)]) | 0;
        f64[i & 3] = i / 3;
        sum += f64[(i + 1) & 3] | 0;
    }
    out("heap " + sum + " " + show(f64[3]) + " " + show(h32[2]));
    // A detached buffer reads undefined and drops stores.
    var dbuf = new ArrayBuffer(16), dv = new Int32Array(dbuf);
    for (var i = 0; i < 4; i++) put(dv, i, i + 1);
    var before = get(dv, 1);
    if (typeof structuredClone === "function") structuredClone(dbuf, { transfer: [dbuf] });
    else if (typeof dbuf.transfer === "function") dbuf.transfer();
    put(dv, 1, 9);
    out("detached " + before + " " + show(get(dv, 1)) + " " + dv.length);
    // A resizable buffer and a length-tracking view.
    if (typeof ArrayBuffer.prototype.resize === "function") {
        var rb = new ArrayBuffer(8, { maxByteLength: 32 }), rv = new Uint16Array(rb);
        for (var i = 0; i < 4; i++) put(rv, i, i * 1000);
        rb.resize(4);
        out("resizable " + show(get(rv, 1)) + " " + show(get(rv, 3)) + " " + rv.length);
    }
    // A proxy over a typed array, and a typed array as a prototype.
    var tp = new Proxy(new Int32Array(4), {});
    put(tp, 1, 3); out("proxy " + get(tp, 1));
    var sub = Object.create(new Int32Array([4, 5]));
    out("proto " + show(get(sub, 1)) + " " + show(get(sub, 0)));
    // Elements and the switch path mixed at one site.
    var mixed = [new Int32Array([1, 2]), [3, 4], new Float64Array([5.5, 6.5]), { 1: "x" }, "ab"];
    var ms = [];
    for (var r = 0; r < 4; r++) for (var m = 0; m < mixed.length; m++) ms.push(show(get(mixed[m], 1)));
    out("mixed " + ms.join(","));
})();

// --- Bitwise operators on booleans, undefined and null ---
(function () {
    var vals = [undefined, null, true, false, 0, -0, 7, -1, 2147483647, -2147483648,
                4294967295, 3000000000.5, -1.5, NaN, Infinity, "9", { valueOf: function () { return 6; } }];
    function bits(a, b) { return [a & b, a | b, a ^ b, a << b, a >> b, a >>> b, a | 0, a & 255, a >>> 0, ~a].join(" "); }
    var acc = [];
    for (var r = 0; r < 3; r++)
        for (var i = 0; i < vals.length; i++)
            for (var j = 0; j < vals.length; j += 3) acc.push(bits(vals[i], vals[j]));
    out("bits " + acc.length + " " + acc[0] + " | " + acc[5] + " | " + acc[acc.length - 1]);
    try { out(1n & true); } catch (e) { out("bigint & bool " + e.name); }
})();

// --- Integral double keys on arrays and typed arrays ---
(function () {
    function rw(a, keys) {
        var r = [];
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i];
            r.push(show(a[k]));
            a[k] = i;
            r.push(show(a[k]));
        }
        return r.join(",");
    }
    var half = 0.5;
    var keys = [0, half * 2, 4 / 2, 1.5, -0 * half, -1 * 1, half * 6, half * 8, 2147483648 * 1.0, NaN, Infinity, 1e300];
    for (var r = 0; r < 3; r++) {
        out("dkey arr " + rw([10, 20, 30, , 50], keys));
        out("dkey i32 " + rw(new Int32Array(4), keys));
        out("dkey f64 " + rw(new Float64Array(3), keys));
        var o = { "1": "one", "1.5": "x" };
        out("dkey obj " + rw(o, keys) + " " + Object.keys(o).join("|"));
    }
})();

// --- Compound element assignment (GETPROP_CACHE) ---
(function () {
    var a = [1, 2, 3], o = { p: 1, q: "s" }, t = new Uint8Array(4);
    var ks = ["p", "q", "p"];
    for (var i = 0; i < 300; i++) {
        a[i % 3] += i;
        o[ks[i % 3]] += 1;
        t[i & 3] += 7;
        a[(i % 3) / 1] *= 1;
    }
    out("compound " + a + " " + o.p + " " + o.q.length + " " + Array.prototype.join.call(t));
})();

// --- Polymorphic reads, shape changes and prototype methods ---
(function () {
    function mk(n) {
        var objs = [];
        for (var i = 0; i < n; i++) { var o = {}; o["p" + i] = i; o.x = i * 10; o.y = "s" + i; objs.push(o); }
        return objs;
    }
    function readx(o) { return o.x; }
    function ready(o) { return o.y; }
    function Pt(x) { this.x = x; }
    Pt.prototype.get = function () { return this.x; };
    function run(n) {
        var objs = mk(n), s = 0, t = "";
        for (var r = 0; r < 50; r++) for (var i = 0; i < objs.length; i++) { s += readx(objs[i]); t = ready(objs[i]); }
        objs[0].x = 99; delete objs[1].x; objs[2].x = "str";
        Object.defineProperty(objs[n - 1], "x", { get: function () { return "getter"; } });
        for (var i = 0; i < objs.length; i++) t += "," + readx(objs[i]);
        var p = new Pt(4), q = Object.create(Pt.prototype); q.z = 1; q.x = 7;
        for (var i = 0; i < 20; i++) s += p.get() + q.get();
        return s + t;
    }
    out("poly " + run(3) + " " + run(5) + " " + run(6) + " " + run(9));
})();

// --- Variables in scopes with eval, cells and remainders ---
(function () {
    function scoped(n) {
        eval("var ev = " + n);
        var s = 0;
        for (var i = 0; i < 20; i++) { s += ev; ev = ev + 1; ev++; }
        return s + ev;
    }
    var t = 0;
    for (var k = 0; k < 40; k++) t += scoped(k);
    var fs = [];
    for (let i = 0; i < 30; i++) fs.push(function () { i += 2; return i % 7; });
    var m = 0;
    for (var r = 0; r < 5; r++) for (var j = 0; j < fs.length; j++) m += fs[j]();
    var rem = [];
    for (var i = -3; i < 40; i++) rem.push(i % 5, i % -3, (i * 0.5) % 2);
    out("vars " + t + " " + m + " " + rem.slice(0, 12).map(show).join(","));
})();

// --- Functions wide enough to need WIDE operands ---
(function () {
    var src = "var c = 0; var arr = [1, 2, 3]; var buf = new Int32Array(8);\n";
    for (var i = 0; i < 300; i++) src += "var v" + i + " = " + i + ";\n";
    var locals = "";
    for (var i = 0; i < 280; i++) locals += "var w" + i + " = v" + i + " + 1; ";
    src += "function inner() { " + locals + "v1 = w279 - w0; return v299 + v0 + c + v1; }\n";
    src += "for (var k = 0; k < 50; k++) { c += inner(); arr[k % 3] = v298 + k; buf[k & 7] = arr[k % 3]; c += buf[(k + 1) & 7]; v299 = v299 + 1; }\n";
    src += "return [c, arr.join(), Array.prototype.join.call(buf), v299].join(' ');";
    var wide = new Function(src);
    for (var r = 0; r < 3; r++) out("wide " + wide());
})();

// --- Objects moving through registers during incremental marking ---
(function () {
    var keep = [], sum = 0;
    for (var i = 0; i < 60000; i++) {
        var o = { v: i, next: keep.length ? keep[keep.length - 1] : null };
        var p = o, q = p.next;
        if (q) sum += q.v;
        if ((i & 15) === 0) keep.push(p);
        if (keep.length > 500) keep = keep.slice(250);
        var junk = [i, i + 1, { a: i }];
        sum += junk.length;
    }
    out("marking " + sum + " " + keep.length);
})();

var asyncDone = (async function () {
    async function sq(x) { await null; return x * x; }
    var s = 0;
    for (var i = 0; i < 200; i++) s += await sq(i);
    out("async " + s);
    async function fails() { await 1; throw new Error("boom"); }
    try { await fails(); } catch (e) { out("async caught " + e.message); }
    async function* agen(n) { for (var i = 0; i < n; i++) { await null; yield i; } }
    var parts = [];
    for await (var v of agen(50)) parts.push(v);
    out("async gen " + parts.length + " " + parts[49]);
    async function hotAwait() {
        var t = 0;
        for (var i = 0; i < 5000; i++) { t += i; if (i % 2000 === 0) await t; }
        return t;
    }
    out("hot await " + await hotAwait());
    var order = [];
    await Promise.all([1, 2, 3].map(async function (k) { order.push("a" + k); await null; order.push("b" + k); }));
    out("order " + order.join(","));
    async function* yieldStar() { yield* agen(3); yield* [7, 8]; }
    var ys = []; for await (var y of yieldStar()) ys.push(y);
    out("async yield* " + ys);
})();

asyncDone.then(function () {
    for (var li = 0; li < lines.length; li++) print(lines[li]);
    print("jit_baseline_misc: " + lines.length + " lines");
}, function (e) { print("async failure " + e); });
