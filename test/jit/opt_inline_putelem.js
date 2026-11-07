// PUTPROP of an element in an inlined callee, for values of every kind: the dense fast store, the
// counted store (strings and objects, a live numeric node across it), holes, undefined, out of
// bounds, appends, frozen arrays, typed arrays, setters on the prototype, and GC pressure.
var out = [];
function show(label, v) { out.push(label + "=" + (Object.is(v, -0) ? "-0" : String(v))); }

// The store index is computed: a plain `arr[i] = v` copies the value with LDREG, which an inlined body cannot hold.
function put(arr, i, v) { arr[i + 1] = v; return i; }
function put2(arr, i, v) { arr[i + 1] = v; arr[i + 2] = v; return i; }
// The index, a computed number and the stored value all live in registers across the store.
function putmix(arr, i, v, n) { var k = n + 1; arr[i + 1] = v; return k + n + i; }

var base = [1, 2, 3, 4, 5, 6, 7, 8];
for (var i = 0; i < 3000; i++) { put(base, i % 8, i); put2(base, i % 6, i); putmix(base, i % 8, i, i); }

function caller(arr, i, v, n) {
    var t = 0.5 + n;
    put(arr, i, v);
    put2(arr, i, v);
    t += putmix(arr, i, v, n);
    return t;
}
var warmarr = [1, 2, 3, 4, 5, 6, 7, 8];
var acc = 0;
for (var i = 0; i < 6000; i++) acc += caller(warmarr, i % 6, i, i % 9);
show("warm", acc + "|" + warmarr.join());

function fresh() { return [1, 2, 3, 4, 5, 6, 7, 8]; }
var objv = { x: 1 };
var values = [7, 0.5, -0, NaN, "str", "", objv, [1, 2], null, undefined, true, 2147483647, function () {}, Symbol.iterator];
function render(a) { return Array.prototype.map.call(a, function (e, k) { return typeof e + ":" + (typeof e === "symbol" ? "sym" : typeof e === "function" ? "fn" : typeof e === "object" && e !== null ? "obj" : String(e)); }).join(","); }
for (var j = 0; j < values.length; j++) {
    var a = fresh();
    var r = caller(a, 1, values[j], 3);
    show("val" + j, r + "|" + render(a));
}

// Overwriting a string element and an object element (the old value needs the count).
var a = ["a", "b", { y: 1 }, "d", 5, 6, 7, 8];
caller(a, 0, 1, 1); caller(a, 2, "z", 1); caller(a, 3, objv, 1);
show("overwrite", render(a));

// Holes, out of bounds, appends, negative and fractional indexes.
var h = [1, , 3, 4, 5, 6, 7, 8];
caller(h, 1, "hole", 1);
show("hole", render(h));
var cases = [[10, "x"], [8, "y"], [9, {}], [-1, "neg"], [1.5, "frac"], [100, 5], [3, undefined]];
for (var k = 0; k < cases.length; k++) {
    var a = fresh();
    var r = caller(a, cases[k][0], cases[k][1], 2);
    show("idx" + k, r + "|" + a.length + "|" + render(a) + "|" + Object.keys(a).join(" "));
}

// Frozen, sealed and non-extensible arrays.
var frozen = Object.freeze(fresh());
var sealed = Object.seal(fresh());
var noext = Object.preventExtensions(fresh());
[frozen, sealed, noext].forEach(function (arr, k) {
    var r;
    try { r = caller(arr, 2, "q", 1); caller(arr, 8, "app", 1); } catch (e) { r = "throws " + e.name; }
    show("lock" + k, r + "|" + render(arr));
});

// Typed arrays.
var types = [Int32Array, Float64Array, Uint8Array, Float32Array, Int16Array, Uint8ClampedArray];
for (var k = 0; k < types.length; k++) {
    var ta = new types[k](8);
    var res = [];
    var vs = [3, 300, -1, 2.7, "5", {}, undefined];
    for (var j = 0; j < vs.length; j++) {
        try { res.push(caller(ta, 2, vs[j], 1) + ":" + ta[2]); } catch (e) { res.push("throws " + e.name); }
    }
    res.push(caller(ta, 20, 1, 1));
    show("typed" + k, res.join(" "));
}

// Setters and read-only elements on the prototype, and an array-like object, a string, null.
var log = [];
var proto = Object.create(Array.prototype);
Object.defineProperty(Array.prototype, 11, { set: function (v) { log.push("set" + v); }, configurable: true });
var ap = fresh();
caller(ap, 11, "viaSetter", 1);
show("setter", log.join() + "|" + ap.length + "|" + Object.keys(ap).join(" "));
delete Array.prototype[11];
var plain = { length: 0 };
var r1 = caller(plain, 1, "p", 1);
show("object", r1 + "|" + JSON.stringify(plain));
var r2;
try { r2 = caller(null, 0, 1, 1); } catch (e) { r2 = "throws " + e.name; }
show("null", r2);
var sa = { set 0(v) { log.push("own" + v); } };
caller(sa, 0, "s", 1);
show("ownsetter", log.join());

// GC pressure with objects stored into arrays by an inlined callee.
var big = new Array(64);
for (var i = 0; i < 64; i++) big[i] = 0;
var total = 0;
for (var round = 0; round < 3000; round++) {
    for (var i = 0; i < 64; i += 7) {
        caller(big, i, { n: round + i, s: "s" + round }, i & 3);
        put(big, (i + 1) % 64, "k" + round + "_" + i);
    }
}
for (var i = 0; i < 64; i++) {
    var e = big[i];
    total += typeof e === "object" ? e.n + e.s.length : typeof e === "string" ? e.length : e;
}
show("gc", total);
var keep = [];
for (var i = 0; i < 2000; i++) { var holder = [null, null, null, null, null, null, null, null]; caller(holder, i % 8, { v: i }, 1); if (i % 100 === 0) keep.push(holder); }
var kt = 0;
for (var i = 0; i < keep.length; i++) for (var j = 0; j < 8; j++) { var e = keep[i][j]; if (e && typeof e === "object") kt += e.v; }
show("keep", kt);

print(out.join("\n"));
