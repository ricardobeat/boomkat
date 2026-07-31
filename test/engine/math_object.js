// Math functions
// Tests Math object properties and methods.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

function approx(a, b, eps) {
    if (eps === undefined) eps = 1e-10;
    return Math.abs(a - b) < eps;
}

// Properties
assert(Math.PI > 3.14 && Math.PI < 3.15, "Math.PI");
assert(approx(Math.E, 2.718281828, 1e-6), "Math.E");
assert(approx(Math.LN2, 0.693147180, 1e-6), "Math.LN2");
assert(approx(Math.LN10, 2.302585092, 1e-6), "Math.LN10");
assert(approx(Math.SQRT2, 1.414213562, 1e-6), "Math.SQRT2");
assert(Math.SQRT1_2 < 1, "Math.SQRT1_2");

// Rounding
assert(Math.floor(3.7) === 3, "floor 3.7");
assert(Math.floor(-3.7) === -4, "floor -3.7");
assert(Math.ceil(3.2) === 4, "ceil 3.2");
assert(Math.ceil(-3.2) === -3, "ceil -3.2");
assert(Math.round(3.5) === 4, "round 3.5");
assert(Math.round(3.4) === 3, "round 3.4");
assert(Math.round(-3.5) === -3, "round -3.5 (banker's-ish)");

// Abs, min, max
assert(Math.abs(-42) === 42, "abs");
assert(Math.abs(0) === 0, "abs zero");
assert(Math.min(3, 1, 4, 1, 5) === 1, "min");
assert(Math.max(3, 1, 4, 1, 5) === 5, "max");
assert(Math.min() === Infinity, "min no args");
assert(Math.max() === -Infinity, "max no args");

// Powers
assert(Math.pow(2, 10) === 1024, "pow 2^10");
assert(Math.pow(9, 0.5) === 3, "pow sqrt");
assert(Math.sqrt(144) === 12, "sqrt 144");
assert(Math.sqrt(2) > 1.414 && Math.sqrt(2) < 1.415, "sqrt 2");

// Logarithms
assert(Math.log(Math.E) === 1, "log(E)=1");
assert(Math.log(1) === 0, "log(1)=0");
assert(Math.log(1024) / Math.log(2) === 10, "log2 via change of base");

// Trig
assert(approx(Math.sin(0), 0), "sin(0)");
assert(approx(Math.sin(Math.PI / 6), 0.5), "sin(PI/6)");
assert(approx(Math.cos(0), 1), "cos(0)");
assert(approx(Math.cos(Math.PI), -1), "cos(PI)");
assert(approx(Math.tan(Math.PI / 4), 1), "tan(PI/4)");
assert(approx(Math.atan2(1, 1), Math.PI / 4), "atan2(1,1)");

// Random returns [0, 1)
for (var i = 0; i < 100; i++) {
    var r = Math.random();
    if (r < 0 || r >= 1) { fail++; print("FAIL: random out of [0,1)"); break; }
}
pass++;

// Sign
assert(Math.sign(5) === 1, "sign positive");
assert(Math.sign(-5) === -1, "sign negative");
assert(Math.sign(0) === 0, "sign zero");

// Trunc
assert(Math.trunc(3.7) === 3, "trunc positive");
assert(Math.trunc(-3.7) === -3, "trunc negative");

print("engine/math_object: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
