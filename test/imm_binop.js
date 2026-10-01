// A literal operand folds into MULI/BANDI/BORI/BXORI/SHLI/SHRI/USHRI. Every
// folded form must agree with the register form on the same operands, for
// fastints, doubles, -0, overflow, coercions, and thrown errors.
var ops = ["*", "&", "|", "^", "<<", ">>", ">>>"];
var imms = [0, 1, 2, 3, 7, 31, 32, 100, 127, 128, 255];
var vals = [0, 1, -1, 5, -5, 255, 0x3FFFFFFF, 0x40000000, 0x7FFFFFFF, 0xFFFFFFFF, 2147483648,
            Math.pow(2, 47), Math.pow(2, 53), -0, 1.5, -2.5, NaN, Infinity, "7", "x", "", null, undefined,
            true, [], [3], {valueOf: function () { return 9; }}, 5n];

function outcome(f, x) {
    try { return f(x); } catch (e) { return e.name; }
}
function same(a, b) { return Object.is(a, b); }

var checked = 0;
for (var oi = 0; oi < ops.length; oi++) {
    for (var ii = 0; ii < imms.length; ii++) {
        var op = ops[oi], imm = imms[ii];
        var folded = new Function("x", "return x " + op + " " + imm);
        var viaReg = new Function("x", "var y = " + imm + "; y = y + 0 * x.length; return x " + op + " y");
        var regForm = new Function("x", "y", "return x " + op + " y");
        for (var vi = 0; vi < vals.length; vi++) {
            var x = vals[vi];
            var want = outcome(function (v) { return regForm(v, imm); }, x);
            var got = outcome(folded, x);
            if (!same(got, want)) throw new Error("x " + op + " " + imm + " with " + String(x) + ": " + String(got) + " != " + String(want));
            checked++;
        }
    }
}

// Commutative operators fold a left-hand literal too.
var comm = ["*", "&", "|", "^"];
for (var ci = 0; ci < comm.length; ci++) {
    for (var ii2 = 0; ii2 < imms.length; ii2++) {
        var cop = comm[ci], cimm = imms[ii2];
        var lf = new Function("x", "return " + cimm + " " + cop + " x");
        var lr = new Function("x", "y", "return y " + cop + " x");
        for (var vj = 0; vj < vals.length; vj++) {
            var lw = outcome(function (v) { return lr(v, cimm); }, vals[vj]);
            var lg = outcome(lf, vals[vj]);
            if (!same(lg, lw)) throw new Error(cimm + " " + cop + " x with " + String(vals[vj]) + ": " + String(lg) + " != " + String(lw));
            checked++;
        }
    }
}

// An operand with a valueOf runs it exactly once, and the literal never reorders it.
var calls = 0;
var o = {valueOf: function () { calls++; return 6; }};
function side(x) { return [x * 2, 3 & x, x << 1, x >>> 1]; }
var r = side(o);
if (calls !== 4 || r.join() !== "12,2,12,3") throw new Error("valueOf " + calls + " " + r);

// A negative literal stays a register operand for the unsigned forms.
function neg(x) { return [x & -1, x ^ -1, x | -2, x * -3]; }
if (neg(5).join() !== "5,-6,-1,-15") throw new Error("negative literals " + neg(5));

// -0 from a zero product of opposite signs.
function negzero(x) { return x * 3; }
if (!Object.is(negzero(-0), -0)) throw new Error("-0 * 3");
function negzero2(x) { return x * -4; }
if (!Object.is(negzero2(0), -0)) throw new Error("0 * -4");

// Products that leave the fastint range become doubles.
function wide(x) { return x * 100; }
if (wide(Math.pow(2, 46)) !== Math.pow(2, 46) * 100) throw new Error("wide product");
