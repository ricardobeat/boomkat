// Element reads and writes in the optimizing tier: dense arrays, typed arrays of every
// kind, holes, out-of-range and non-integer indices, and values that are not numbers.
var out = [];

function sumTyped(a, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += a[i];
    return s;
}
function fillTyped(a, n, scale, off) {
    for (var i = 0; i < n; i++) a[i] = i * scale - off;
    return a;
}
var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
for (var k = 0; k < kinds.length; k++) {
    var t = new kinds[k](40);
    fillTyped(t, 40, 3, 20);
    var u = new kinds[k](40);
    fillTyped(u, 40, 0.75, 7.5);
    out.push(kinds[k].name + ":" + sumTyped(t, 40) + ":" + sumTyped(u, 40) + ":" + sumTyped(t, 45));
}

function dense(a, n) {
    var s = 0;
    for (var i = 0; i < n; i++) s += a[i];
    return s;
}
out.push(dense([1, 2, 3, 4], 4));
out.push(dense([1, 2, 3, 4], 6));
out.push(dense([1.5, 2.5, -0.5], 3));
out.push(dense([1, , 3], 3));
Array.prototype[1] = 10;
out.push(dense([1, , 3], 3));
delete Array.prototype[1];
out.push(dense([1, "2", 3], 3));
out.push(dense([1, undefined, 3], 3));
out.push(dense([1, null, true], 3));

function neg(a) { var i = -1; return a[i] + "," + a[i + 1] + "," + a[i + 5]; }
out.push(neg([5, 6, 7]));
function dbl(a, n) { var s = ""; for (var i = 0; i < n; i++) s += a[i / 2 * 2] + ";"; return s; }
out.push(dbl([1, 2, 3, 4], 4));
function half(a) { var s = ""; for (var i = 0; i < 4; i++) s += a[i * 0.5] + ";"; return s; }
out.push(half([1, 2, 3, 4]));

function store(a, n, v) {
    for (var i = 0; i < n; i++) a[i] = v + i;
    return a.join(",");
}
out.push(store([0, 0, 0], 3, 5));
out.push(store([0, 0, 0], 3, 0.5));
out.push(store([0, 0, 0], 5, 1));
out.push(store(["a", "b", "c"], 3, 2));
out.push(store([0, , 0], 3, 2));
out.push(store(new Int32Array(3), 3, 0.5));
out.push(store(new Uint8Array(3), 3, 254));
out.push(store(new Uint8ClampedArray(3), 3, 254.5));
out.push(store(new Float32Array(3), 3, 0.1));

function negzero() {
    var a = new Float64Array(2);
    var z = 0;
    for (var i = 0; i < 2; i++) a[i] = -z;
    return (1 / a[0]) + ":" + (1 / a[1]) + ":" + (a[0] === 0);
}
out.push(negzero());
function nan() {
    var a = new Float64Array(2);
    var z = 0;
    for (var i = 0; i < 2; i++) a[i] = z / z;
    return isNaN(a[0]) + ":" + isNaN(a[1]);
}
out.push(nan());

function mixed(o, keys) {
    var s = 0;
    for (var i = 0; i < keys.length; i++) s += o[keys[i]];
    return s;
}
out.push(mixed({ a: 1, b: 2, 0: 10, 1: 20 }, ["a", 0, "b", 1]));
out.push(mixed([5, 6, 7], [0, 1, 2]));
out.push(mixed([5, 6, 7], ["0", 1, "2"]));

function swapPairs(a) {
    for (var i = 0; i + 1 < a.length; i += 2) {
        var t = a[i];
        a[i] = a[i + 1];
        a[i + 1] = t;
    }
    return a.join(",");
}
out.push(swapPairs([1, 2, 3, 4, 5, 6]));
out.push(swapPairs([1.5, 2, 3, 4.5]));
out.push(swapPairs(new Float64Array([1.5, 2, 3, 4.5])));

function grow(a) { for (var i = 0; i < 6; i++) a[i] = i * 2; return a.length + ":" + a.join(","); }
out.push(grow([]));
out.push(grow([9]));

function notObject(x) { var s = 0; for (var i = 0; i < 3; i++) s += x[i]; return s; }
out.push(notObject("abc") + "");
out.push(notObject(5) + "");
function big(a) { return a[2147483647] + ":" + a[4294967296]; }
out.push(big([1]));

var line = out.join("|");
var expected = "Int8Array:1540:278:NaN|Uint8Array:3332:2582:NaN|Uint8ClampedArray:1617:327:NaN|Int16Array:1540:278:NaN|Uint16Array:460292:590102:NaN|Int32Array:1540:278:NaN|Uint32Array:30064772612:38654705942:NaN|Float32Array:1540:285:NaN|Float64Array:1540:285:NaN|10|NaN|3.5|NaN|14|123|NaN|2|undefined,5,undefined|1;2;3;4;|1;undefined;2;undefined;|5,6,7|0.5,1.5,2.5|1,2,3,4,5|2,3,4|2,3,4|0,1,2|254,255,0|254,255,255|0.10000000149011612,1.100000023841858,2.0999999046325684|-Infinity:-Infinity:true|true:true|33|18|18|2,1,4,3,6,5|2,1.5,4.5,3|2,1.5,4.5,3|6:0,2,4,6,8,10|6:0,2,4,6,8,10|0abc|NaN|undefined:undefined";
print(line === expected ? "opt_elements ok" : "opt_elements FAIL\n" + line + "\n" + expected);
