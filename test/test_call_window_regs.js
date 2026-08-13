// A call's register window extends past the allocator's high-water mark: the
// VM overlays the callee frame at callee_reg, with the receiver at
// callee_reg+1 and arguments above it, but max_reg only counts registers
// alloc_reg handed out. Anything sized by max_reg alone therefore excludes the
// window's top slot.
//
// That bit the move-elimination pass, whose per-instruction liveness bitsets
// were (max_reg + 31) / 32 words wide: when max_reg landed on a multiple of 32
// the receiver slot fell outside the bitset, moveelim_mark_range clamped it,
// the slot never looked live, and the LDREG loading `this` was deleted as a
// dead store. The method then ran with whatever the register held -- undefined
// in practice, so `this.anything` threw. Babel 7.24.7 hit it in the tokenizer;
// 12 of its functions met the exact condition.
//
// This sweeps a range of register pressures so at least one function in the
// suite lands on each boundary, and asserts every call sees its receiver.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

var seen = [];
var host = {
    tag: "HOST",
    probe: function () { seen.push(this === undefined ? "NOTHIS" : this.tag); },
    probeArgs: function (a, b) { seen.push(this === undefined ? "NOTHIS" : this.tag + ":" + (a + b)); },
    s: {}
};

// Build methods whose bodies consume a growing number of registers before the
// trailing method call, so the receiver slot sweeps across the word boundaries
// the liveness bitset is sized in.
function build(stmts, args) {
    var src = "(function () {\n";
    for (var i = 0; i < stmts; i++) {
        src += "  this.s.x" + i + " = this.s.y" + i + ";\n";
    }
    src += args === 0 ? "  this.probe();\n" : "  this.probeArgs(1, 2);\n";
    src += "})";
    return eval(src);
}

var built = 0;
for (var stmts = 0; stmts < 40; stmts++) {
    for (var args = 0; args < 2; args++) {
        var fn = build(stmts, args);
        fn.call(host);
        built++;
    }
}
ck("every-call-kept-its-receiver", seen.indexOf("NOTHIS"), -1);
ck("every-call-ran", seen.length, built);

// Nested chains raise register pressure differently from flat assignments,
// so sweep those too.
seen = [];
built = 0;
for (var d = 0; d < 24; d++) {
    var src = "(function () {\n";
    for (var i = 0; i < d; i++) {
        src += "  this.s.a" + i + " = { k: this.s.b" + i + " };\n";
    }
    src += "  this.probe();\n})";
    var fn2 = eval(src);
    fn2.call(host);
    built++;
}
ck("nested-chains-kept-receiver", seen.indexOf("NOTHIS"), -1);
ck("nested-chains-ran", seen.length, built);

// A receiver held in a local, rather than reloaded from `this`, must survive
// the same way.
seen = [];
var viaLocal = function () {
    var self = this;
    this.s.p0 = this.s.q0;
    this.s.p1 = this.s.q1;
    self.probe();
};
viaLocal.call(host);
ck("receiver-via-local", seen.join(","), "HOST");

// Arguments above the receiver must survive too: they occupy the same window.
seen = [];
var withArgs = function () {
    this.s.p0 = this.s.q0;
    this.probeArgs(10, 20);
};
withArgs.call(host);
ck("args-above-receiver", seen.join(","), "HOST:30");

// A call in the last statement position, where the frame is widest and the
// window most likely to sit at the very top of the register file.
seen = [];
var trailing = function () {
    var a = this.s, b = this.s, c = this.s, d = this.s, e = this.s;
    this.s.z0 = a; this.s.z1 = b; this.s.z2 = c; this.s.z3 = d; this.s.z4 = e;
    this.probe();
};
trailing.call(host);
ck("trailing-call", seen.join(","), "HOST");

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error("FAIL"); }
