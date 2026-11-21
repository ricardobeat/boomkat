// Math calls baseline code computes inline (Asm.emit_math): fastint arguments of floor, ceil, round,
// abs, min and max as integers, everything else as doubles, by the machine's instruction or the
// function the builtin calls. Each site is warmed up, then given the values whose results differ
// from the obvious (-0, NaN, infinities, the least fastint), arguments that are no numbers, and a
// callee that is no longer the builtin.
var out = [];
function log(x) { out.push(String(x)); }
// Fourteen digits, past which libm implementations differ in the last place of tan and atan.
function show(v) { return Object.is(v, -0) ? "-0" : Number.isInteger(v) || !isFinite(v) ? String(v) : String(+v.toPrecision(14)); }

function m1(x) {
    return [Math.floor(x), Math.ceil(x), Math.round(x), Math.abs(x), Math.sqrt(x), Math.sin(x),
            Math.cos(x), Math.tan(x), Math.exp(x), Math.log(x), Math.atan(x)];
}
function m2(x, y) { return [Math.min(x, y), Math.max(x, y), Math.pow(x, y), Math.atan2(x, y)]; }

var acc = 0;
for (var i = 0; i < 400; i++) {
    var r = m1(i - 200), s = m1((i - 200) * 0.37), t = m2(i - 200, 7), u = m2(i * 0.5, -3.25);
    for (var k = 0; k < r.length; k++) acc += (r[k] === r[k] ? r[k] : 0) + (s[k] === s[k] ? s[k] : 0);
    for (var k = 0; k < t.length; k++) acc += (t[k] === t[k] && isFinite(t[k]) ? t[k] : 0) + (u[k] === u[k] ? u[k] : 0);
}
log(acc.toFixed(6));

var edge = [0, -0, 0.5, -0.5, 0.4999999999999999, -0.4, 2.5, -2.5, 1e300, -1e300, Infinity, -Infinity, NaN,
            140737488355327, -140737488355328, 140737488355328, 2147483648, -2147483649, 1e-310, 4503599627370497];
for (var e of edge) log(show(e) + ": " + m1(e).map(show).join(" "));
var pairs = [[0, -0], [-0, 0], [NaN, 1], [1, NaN], [3, 3], [-1, 1], [Infinity, -Infinity], [2, 0.5], [-8, 1 / 3],
             [NaN, 0], [1, Infinity], [-1, -Infinity], [0, 0], [-0, -1], [-140737488355328, 1], [5, -0]];
for (var p of pairs) log(show(p[0]) + "," + show(p[1]) + ": " + m2(p[0], p[1]).map(show).join(" "));

// Integral results are fastints, which index arrays as integers.
var table = [];
for (var i = 0; i < 64; i++) table.push(i * 3);
function pick(x) { return table[Math.floor(x)] + table[Math.round(x)] + table[Math.min(x | 0, 63)] + table[Math.abs(-x) | 0]; }
var pk = 0;
for (var i = 0; i < 2000; i++) pk += pick((i % 600) / 10);
log(pk);

// Arguments that are no numbers: strings, booleans, undefined, objects with valueOf, and one that throws.
var odd = ["9", "-2.5", " 16 ", "", "x", true, false, null, undefined, [4], { valueOf: function () { return 2.25; } }];
for (var o of odd) log(m1(o).map(show).join(" ") + " | " + m2(o, 2).map(show).join(" "));
var boom = { valueOf: function () { throw new RangeError("valueOf"); } };
try { m1(boom); log("no throw"); } catch (e) { log(e.name); }
try { m2(1, boom); log("no throw"); } catch (e) { log(e.name); }
log(m1(10n === 10n ? 10 : 0)[0]);
try { Math.sqrt(1n); log("no throw"); } catch (e) { log(e.name); }

// Called without a receiver (CALL_UNDEF_THIS), and with more or fewer arguments than it takes.
var sqrt = Math.sqrt, max = Math.max, floor = Math.floor;
function bare(x) { return sqrt(x) + max(x, 2) + floor(x / 3); }
function counts(x) { return Math.max(x, 1, 2) + Math.min(x) + Math.abs() + Math.max() + Math.floor(x, 9); }
var bc = 0;
for (var i = 0; i < 400; i++) { bc += bare(i); bc += counts(i) === counts(i) ? counts(i) : 0; }
log(bc + " " + show(counts(3)) + " " + show(Math.min()));

// The callee replaced after warm-up: another function, a bound builtin, a Math from another object.
function viaMath(x) { return Math.sqrt(x) + Math.floor(x); }
for (var i = 0; i < 400; i++) viaMath(i);
var realSqrt = Math.sqrt, realFloor = Math.floor;
Math.sqrt = function (x) { return -x; };
Math.floor = realSqrt.bind(null);
log(viaMath(16) + " " + viaMath(2.25));
Math.sqrt = realSqrt;
Math.floor = realFloor;
log(viaMath(16) + " " + viaMath(2.25));
var fake = { sqrt: Math.cos, floor: Math.ceil };
function viaObj(m, x) { return m.sqrt(x) + m.floor(x); }
for (var i = 0; i < 400; i++) viaObj(Math, i);
log(viaObj(Math, 2.5) + " " + viaObj(fake, 2.5));

print(out.join("\n"));
