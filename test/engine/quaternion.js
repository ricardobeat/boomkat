// Quaternion type
// Hamilton's quaternion algebra: q = w + xi + yj + zk.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function Quat(w, x, y, z) {
    this.w = w; this.x = x; this.y = y; this.z = z;
}

function qAdd(a, b) { return new Quat(a.w + b.w, a.x + b.x, a.y + b.y, a.z + b.z); }
function qNeg(a) { return new Quat(-a.w, -a.x, -a.y, -a.z); }
function qSub(a, b) { return qAdd(a, qNeg(b)); }

// Hamilton product:
//   (a + bi + cj + dk) * (e + fi + gj + hk)
// = ae - bf - cg - dh
// + (af + be + ch - dg)i
// + (ag - bh + ce + df)j
// + (ah + bg - cf + de)k
function qMul(a, b) {
    var w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
    var x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
    var y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
    var z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
    return new Quat(w, x, y, z);
}

function qNorm(a) {
    return Math.sqrt(a.w * a.w + a.x * a.x + a.y * a.y + a.z * a.z);
}

function qConj(a) { return new Quat(a.w, -a.x, -a.y, -a.z); }

// q * conj(q) = (norm)^2 (real)
function qDotSelf(a) { return qMul(a, qConj(a)); }

function approxEq(a, b, eps) {
    if (eps === undefined) eps = 1e-9;
    return Math.abs(a - b) < eps;
}

// i * j = k, j * k = i, k * i = j
var i = new Quat(0, 1, 0, 0);
var j = new Quat(0, 0, 1, 0);
var k = new Quat(0, 0, 0, 1);

var ij = qMul(i, j);
assert(approxEq(ij.w, 0) && approxEq(ij.x, 0) && approxEq(ij.y, 0) && approxEq(ij.z, 1), "i*j=k");

var ji = qMul(j, i);
assert(approxEq(ji.w, 0) && approxEq(ji.z, -1), "j*i=-k");

// i^2 = j^2 = k^2 = -1
var ii = qMul(i, i);
assert(approxEq(ii.w, -1) && approxEq(ii.x, 0), "i*i=-1");

var kk = qMul(k, k);
assert(approxEq(kk.w, -1), "k*k=-1");

// Norm
assert(approxEq(qNorm(new Quat(1, 2, 2, 1)), Math.sqrt(10)), "norm");

// q * q^-1 = 1 (real unit)
var q = new Quat(1, 1, 1, 1);
var n2 = q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z;
var inv = new Quat(q.w / n2, -q.x / n2, -q.y / n2, -q.z / n2);
var prod = qMul(q, inv);
assert(approxEq(prod.w, 1) && approxEq(prod.x, 0) && approxEq(prod.y, 0) && approxEq(prod.z, 0), "q * q^-1 = 1");

print("engine/quaternion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");