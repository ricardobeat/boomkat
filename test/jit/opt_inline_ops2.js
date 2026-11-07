// Callees holding ADD_FUSED (an ADD whose result feeds the next ADD), GETPROP of an element and
// BNOT, which the optimizing tier lowers inside an inlined body: ints, doubles, -0, NaN, strings
// (concatenation and the exit path), heap elements, holes, out-of-range indexes, mixed operands.
//
// The callers add 0.5 so that they carry operand feedback; each callee is warmed on integers (or an
// int array) first so that an exit from its inlined body continues in its baseline code.
var out = [];
function show(label, v) { out.push(label + "=" + (Object.is(v, -0) ? "-0" : String(v))); }

function sum3(a, b, c) { return a + b + c; }
function sum4(a, b, c) { var t = a + b; var u = t + c; return u + a; }
function elem(arr, i) { return arr[i]; }
function elem2(arr, i) { return arr[i] + arr[i + 1]; }
function elemobj(arr, i) { var o = arr[i]; return o.x; }
function bnot(a) { return ~a; }
function bnot2(a, b) { return ~a + ~b; }

var ints = [1, 2, 3, 4, 5, 6, 7, 8];
function warm(f, a, b, c) { for (var i = 0; i < 3000; i++) f(a, b, c); }
warm(sum3, 1, 2, 3); warm(sum4, 1, 2, 3); warm(elem, ints, 1); warm(elem2, ints, 1);
warm(bnot, 5); warm(bnot2, 5, 6);
var objs = [{ x: 1 }, { x: 2 }, { x: 3 }];
warm(elemobj, objs, 1);

var vals = [0, 1, -1, 7, 2147483647, -2147483648, 0.5, -0, NaN, Infinity, "3", "", "abc", null, undefined, true];
function run3(label, f) {
    var acc = [];
    for (var i = 0; i < vals.length; i++)
        for (var j = 0; j < vals.length; j += 3) {
            var r = f(vals[i], vals[j], vals[(i + j) % vals.length]);
            acc.push(Object.is(r, -0) ? "-0" : String(r));
        }
    show(label, acc.join(","));
}
function run1(label, f) {
    var acc = [];
    for (var i = 0; i < vals.length; i++) acc.push(String(f(vals[i], vals[(i + 5) % vals.length])));
    show(label, acc.join(","));
}

var s = 0;
for (var i = 0; i < 4000; i++) s += sum3(i, i % 5, 3) + sum4(i, 2, i % 3) + 0.5;
show("sums.warm", s);

function caller(arr, i, a, b) {
    var t = 0.5;
    t += sum3(a, b, i);
    t += sum4(a, b, 1);
    t += bnot(a);
    t += bnot2(a, b);
    t += elem(arr, i);
    t += elem2(arr, i);
    return t;
}
var acc = 0;
for (var i = 0; i < 6000; i++) acc += caller(ints, i % 6, i % 13, (i % 7) + 1);
show("caller.warm", acc);
// Mixed operands only once the caller is optimized.
run3("sum3", sum3);
run3("sum4", sum4);
run1("bnot", bnot);
run1("bnot2", bnot2);
var cases = [
    [ints, 0, 2147483647, 1], [ints, 3, 0.5, 2], [ints, 3, 1, 0.5], [ints, 2, NaN, 1], [ints, 2, -0, -0],
    [ints, 0, "4", 3], [ints, 0, 4, "3"], [ints, 100, 1, 2], [ints, -1, 1, 2], [ints, 7, 1, 2], [ints, 1.5, 1, 2],
    [[1, , 3, 4, 5, 6, 7, 8], 1, 1, 2], [[1, 0.5, "s", 4, 5, 6, 7, 8], 1, 1, 2], [[1, 2, 3, 4, 5, 6, 7, 8], 2, 1, 2],
    [{ 0: 1, 1: 2, 2: 3 }, 1, 1, 2], ["abcdefgh", 1, 1, 2], [new Float64Array(8), 1, 1, 2], [null, 0, 1, 2],
];
for (var k = 0; k < cases.length; k++) {
    var r;
    try { r = caller(cases[k][0], cases[k][1], cases[k][2], cases[k][3]); } catch (e) { r = "throws " + e.name; }
    show("caller" + k, r);
}

// Elements that are heap values, read in an inlined callee and used after it returns.
function user(arr, i) { var o = arr[i]; return o; }
var mixed = [{ x: 1 }, "str", [1, 2], { x: 4 }, null, undefined, 3.5, 7];
var cnt = 0;
for (var i = 0; i < 6000; i++) {
    var v = user(mixed, i % 8);
    if (v !== null && v !== undefined && typeof v === "object") cnt += v.length === undefined ? v.x : v.length;
    else if (typeof v === "string") cnt += v.length;
    else cnt += 0.5;
}
show("heap", cnt);
var thrown = 0, total = 0;
for (var i = 0; i < 5000; i++) {
    try { total += elemobj(objs, i % 50 === 49 ? 7 : i % 3); } catch (e) { thrown++; }
}
show("elemobj", total + "/" + thrown);

print(out.join("\n"));
