// Callees holding LNOT, MOD, comparisons that produce a boolean value and THROW, which the
// optimizing tier now lowers inside an inlined body (and in its own body): ints, doubles, -0, NaN,
// strings (the exit path), a negative dividend, a zero or negative divisor, a throw after the callee
// frame is published.
//
// The callers add 0.5 so that they carry operand feedback; each callee is warmed on integers first
// so that an exit from its inlined body continues in its baseline code.
var out = [];
function show(label, v) { out.push(label + "=" + (Object.is(v, -0) ? "-0" : String(v))); }

function lnot(a) { return !a; }
function mod(a, b) { return a % b; }
function lt(a, b) { return a < b; }
function le(a, b) { return a <= b; }
function gt(a, b) { return a > b; }
function ge(a, b) { return a >= b; }
function eq(a, b) { return a == b; }
function neq(a, b) { return a != b; }
function seq(a, b) { return a === b; }
function sneq(a, b) { return a !== b; }
function pick(a, b) { var r = a < b; var s = !r; return s ? 1 : 2; }
function thrower(a) { if (a < 0) throw a; return a + 1; }
function modsum(a, b) { return a % b + (a % 3); }

function warm(f, a, b) { for (var i = 0; i < 3000; i++) f(a, b); }
warm(lnot, 1); warm(mod, 7, 3); warm(lt, 1, 2); warm(le, 1, 2); warm(gt, 1, 2); warm(ge, 1, 2);
warm(eq, 1, 2); warm(neq, 1, 2); warm(seq, 1, 2); warm(sneq, 1, 2); warm(pick, 1, 2);
warm(thrower, 1); warm(modsum, 7, 3);

var vals = [0, 1, -1, 7, -7, 3, 2147483647, -2147483648, 0.5, -0.5, -0, NaN, Infinity, "3", "", "abc", null, undefined, true];
function run(label, f, binary) {
    var acc = [];
    for (var i = 0; i < vals.length; i++) {
        if (!binary) { acc.push(String(f(vals[i]))); continue; }
        for (var j = 0; j < vals.length; j++) {
            var r = f(vals[i], vals[j]);
            acc.push(Object.is(r, -0) ? "-0" : String(r));
        }
    }
    show(label, acc.join(","));
}

// Each caller repeats the call so the optimizer sees it (and inlines it) once it is hot, then goes
// through values that fail its speculation.
function drive(f, binary, name) {
    var s = 0;
    for (var i = 0; i < 4000; i++) {
        var r = binary ? f(i % 11, (i % 5) + 1) : f(i % 4);
        s += (r === true ? 1 : (r === false ? 2 : 0)) + 0.5;
    }
    show(name + ".warm", s);
    run(name, f, binary);
}
drive(lnot, false, "lnot");
drive(mod, true, "mod");
drive(lt, true, "lt");
drive(le, true, "le");
drive(gt, true, "gt");
drive(ge, true, "ge");
drive(eq, true, "eq");
drive(neq, true, "neq");
drive(seq, true, "seq");
drive(sneq, true, "sneq");
drive(pick, true, "pick");
drive(modsum, true, "modsum");

// A caller loop that inlines each callee, then meets values off the fast path.
function caller(a, b) {
    var t = 0.5;
    if (lnot(a)) t += 1;
    t += mod(a, b);
    if (lt(a, b)) t += 2;
    if (le(a, b)) t += 3;
    if (gt(a, b)) t += 4;
    if (ge(a, b)) t += 5;
    if (eq(a, b)) t += 6;
    if (neq(a, b)) t += 7;
    if (seq(a, b)) t += 8;
    if (sneq(a, b)) t += 9;
    return t + pick(a, b);
}
var acc = 0;
for (var i = 0; i < 6000; i++) acc += caller(i % 13, (i % 7) + 1);
show("caller.warm", acc);
var cases = [[-5, 3], [5, -3], [5, 0], [-6, 3], [0.5, 2], [5, 0.5], [NaN, 1], [1, NaN], ["4", 3], [4, "3"], [-0, 5], [9, 9], [2147483647, 2], [-2147483648, -1]];
for (var k = 0; k < cases.length; k++) show("caller" + k, caller(cases[k][0], cases[k][1]));

// A negative dividend whose remainder is zero is -0.
function negzero(a, b) { return a % b; }
warm(negzero, 7, 3);
show("negzero", negzero(-6, 3));
show("negzero2", negzero(6, -3));
show("modzero", negzero(6, 0));

// THROW inside an inlined callee: the callee's frame is published and its baseline code throws.
function user(a) { return thrower(a) + 0.5; }
var thrown = 0;
var sum = 0;
for (var i = 0; i < 5000; i++) {
    try { sum += user(i % 50 === 49 ? -i : i); } catch (e) { thrown += e; }
}
show("thrown", thrown);
show("sum", sum);

print(out.join("\n"));
