// Temperature conversion
// Convert between Celsius, Fahrenheit, Kelvin.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function approxEq(a, b, eps) {
    if (eps === undefined) eps = 1e-9;
    return Math.abs(a - b) < eps;
}

function cToF(c) { return c * 9 / 5 + 32; }
function fToC(f) { return (f - 32) * 5 / 9; }
function cToK(c) { return c + 273.15; }
function kToC(k) { return k - 273.15; }
function fToK(f) { return cToK(fToC(f)); }
function kToF(k) { return cToF(kToC(k)); }

assert(approxEq(cToF(0), 32), "0C = 32F");
assert(approxEq(cToF(100), 212), "100C = 212F");
assert(approxEq(cToF(-40), -40), "-40C = -40F");
assert(approxEq(fToC(32), 0), "32F = 0C");
assert(approxEq(fToC(212), 100), "212F = 100C");
assert(approxEq(cToK(0), 273.15), "0C = 273.15K");
assert(approxEq(kToC(0), -273.15), "0K = -273.15C");
assert(approxEq(fToK(32), 273.15), "32F = 273.15K");
assert(approxEq(kToF(273.15), 32), "273.15K = 32F");

// Humanize: pick a unit based on magnitude
function humanizeTemp(k) {
    if (k < 223.15) return kToC(k).toFixed(1) + " C (cold)";
    if (k < 298.15) return kToC(k).toFixed(1) + " C (cool)";
    if (k < 373.15) return kToC(k).toFixed(1) + " C (warm)";
    return kToC(k).toFixed(1) + " C (hot)";
}

assert(humanizeTemp(cToK(-100)).indexOf("cold") !== -1, "-100C is cold");
assert(humanizeTemp(cToK(20)).indexOf("cool") !== -1, "20C is cool");
assert(humanizeTemp(cToK(50)).indexOf("warm") !== -1, "50C is warm");
assert(humanizeTemp(cToK(200)).indexOf("hot") !== -1, "200C is hot");

print("engine/temperature: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");