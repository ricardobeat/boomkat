// Element accesses the optimizing tier compiles before they have met a typed array, and copies
// between typed arrays whose values have no numeric use: the first leave the optimized code once and
// come back specialized, the second become typed loads and stores. Each must answer what the
// interpreter does.
var out = [];
function show(label, v) { out.push(label + "=" + String(v)); }

// The typed branch runs only after the function is optimized.
function late(a, t, n, typed) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (typed) {
            t[i & 7] = t[(i + 1) & 7] + i;
            s += t[i & 7];
        } else {
            s += a[i & 3];
        }
    }
    return s;
}
var arr = [1, 2, 3, 4];
var i32 = new Int32Array(8);
var s1 = 0;
for (var k = 0; k < 300; k++) s1 += late(arr, i32, 50, false);
show("late-array", s1);
for (var k = 0; k < 300; k++) s1 += late(arr, i32, 50, true);
show("late-typed", s1);
show("late-state", Array.prototype.join.call(i32, ","));

// A plain object reaches a site with no record: its class records as such and the site keeps the
// generic path, without exiting again.
var plain = { 0: 5, 1: 6, 2: 7, 3: 8, 4: 9, 5: 1, 6: 2, 7: 3 };
for (var k = 0; k < 200; k++) s1 += late(arr, plain, 40, true);
show("late-plain", s1 + ":" + plain[3]);

// Copies between typed arrays of every kind, and to a plain array.
function copy(dst, src, n) {
    for (var i = 0; i < n; i++) dst[i] = src[(i * 7) % n];
    for (var i = 0; i + 1 < n; i += 2) {
        var x = dst[i];
        dst[i] = dst[i + 1];
        dst[i + 1] = x;
    }
    return dst;
}
var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
var src = new Float64Array(16);
for (var i = 0; i < 16; i++) src[i] = (i * 37.75) - 200;
for (var c = 0; c < kinds.length; c++) {
    var K = kinds[c];
    var from = new K(16);
    for (var i = 0; i < 16; i++) from[i] = src[i];
    var to = new K(16);
    for (var r = 0; r < 400; r++) copy(to, from, 16);
    show(K.name, Array.prototype.join.call(to, ","));
    // Across kinds: the store converts what the load read.
    var wide = new Float64Array(16);
    for (var r = 0; r < 200; r++) copy(wide, from, 16);
    var narrow = new Int8Array(16);
    for (var r = 0; r < 200; r++) copy(narrow, src, 16);
    show(K.name + "-x", Array.prototype.join.call(wide, ",") + "|" + Array.prototype.join.call(narrow, ","));
}
var u32 = new Uint32Array([4294967295, 2147483648, 1, 0]);
var u32b = new Uint32Array(4);
for (var r = 0; r < 500; r++) copy(u32b, u32, 4);
show("u32-high", Array.prototype.join.call(u32b, ","));
var plainDst = [];
for (var r = 0; r < 300; r++) copy(plainDst, new Int16Array([1, -2, 3, -4]), 4);
show("to-array", plainDst.join(","));

console.log(out.join("\n"));
