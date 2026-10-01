// A literal operand folds into the JMP_*I compare-and-branch forms. Each must
// agree with the register form on every operand type, including NaN (which
// makes every relation false) and values that coerce.
var ops = ["<", "<=", ">", ">=", "===", "!=="];
var imms = [0, 1, 2, -1, -128, 127, 128, 255, 1000];
var vals = [0, 1, 2, -1, 126, 127, 128, -128, -129, 1.5, 0.5, -0, NaN, Infinity, -Infinity, 2147483648,
            Math.pow(2, 47), "1", "x", "", null, undefined, true, false, [], [2], {valueOf: function () { return 2; }}, 1n];

function outcome(f, x) {
    try { return f(x); } catch (e) { return e.name; }
}

var checked = 0;
for (var oi = 0; oi < ops.length; oi++) {
    for (var ii = 0; ii < imms.length; ii++) {
        var op = ops[oi], imm = imms[ii];
        var ifForm = new Function("x", "if (x " + op + " " + imm + ") return 1; return 0;");
        var negForm = new Function("x", "if (!(x " + op + " " + imm + ")) return 1; return 0;");
        var loopForm = new Function("x", "var n = 0; while (x " + op + " " + imm + ") { n = 1; break; } return n;");
        var regForm = new Function("x", "y", "if (x " + op + " y) return 1; return 0;");
        for (var vi = 0; vi < vals.length; vi++) {
            var x = vals[vi];
            var want = outcome(function (v) { return regForm(v, imm); }, x);
            var got = outcome(ifForm, x);
            if (got !== want) throw new Error("if (" + String(x) + " " + op + " " + imm + "): " + got + " != " + want);
            var wantNeg = typeof want === "number" ? 1 - want : want;
            if (outcome(negForm, x) !== wantNeg) throw new Error("if (!(" + String(x) + " " + op + " " + imm + "))");
            if (outcome(loopForm, x) !== want) throw new Error("while (" + String(x) + " " + op + " " + imm + ")");
            checked++;
        }
    }
}

// Backward branches (loop back-edges) with an immediate bound.
function countdown(n) { var steps = 0; do { n--; steps++; } while (n > 0); return steps; }
if (countdown(50) !== 50) throw new Error("countdown");
function spin() { var i = 0, s = 0; while (i !== 7) { i++; s += i; } return s; }
if (spin() !== 28) throw new Error("spin");

// NaN is neither above nor below: the relational forms all stay false.
function nan(x) { return [x < 1, x <= 1, x > 1, x >= 1, x === 1, x !== 1]; }
for (var k = 0; k < 3; k++) {
    if (nan(NaN).join() !== "false,false,false,false,false,true") throw new Error("NaN relations");
}
