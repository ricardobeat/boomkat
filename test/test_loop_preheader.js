// Control-flow torture for the for-loop preheader transform (the entry JUMP is
// retargeted past the condition-block counter load, which is then dropped).
// Every case below either lands on, jumps over, or re-enters the condition
// block; a wrong entry edge or a stale counter register shows up as a wrong
// count, a missing iteration, or a hang.
var out = [];
function ck(name, got) { out.push(name + "=" + got); }

// --- baseline shapes ---
var N = 5, a = 0;
for (var i = 0; i < N; i++) { a++; }
ck("plain", a + "/" + i);

var b = 0;
for (var j = 0; j < 0; j++) { b++; }
ck("zero_trip", b + "/" + j);

var c = 0;
for (var k = 0; k < 1; k++) { c++; }
ck("one_trip", c);

// --- continue: targets the increment, must not re-run the preheader load ---
var d = 0;
for (var m = 0; m < 6; m++) { if (m === 2) continue; d++; }
ck("continue", d + "/" + m);

var d2 = 0;
for (var m2 = 0; m2 < 6; m2++) { if (m2 % 2 === 0) continue; d2++; }
ck("continue_many", d2);

// --- break out of the middle ---
var e = 0;
for (var p = 0; p < 100; p++) { if (p === 4) break; e++; }
ck("break", e + "/" + p);

// --- nested: inner loop re-enters its own preheader on every outer pass ---
var f = 0;
for (var q = 0; q < 4; q++) { for (var r = 0; r < 3; r++) { f++; } }
ck("nested", f + "/" + q + "/" + r);

var g = 0;
for (var s = 0; s < 4; s++) {
  for (var t = 0; t < 3; t++) { if (t === 1) continue; if (s === 3) break; g++; }
}
ck("nested_cf", g);

// --- labeled continue/break jump ACROSS loop levels ---
var h = 0;
outer1:
for (var u = 0; u < 4; u++) { for (var v = 0; v < 3; v++) { if (v === 1) continue outer1; h++; } }
ck("labeled_continue", h);

var l = 0;
outer2:
for (var w = 0; w < 4; w++) { for (var x = 0; x < 3; x++) { if (w === 2) break outer2; l++; } }
ck("labeled_break", l);

// --- the counter is mutated inside the body (load must see the new value) ---
var n2 = 0;
for (var y = 0; y < 8; y++) { n2++; if (y === 1) y = 5; }
ck("body_mutates_counter", n2 + "/" + y);

// --- the bound is mutated inside the body ---
var B = 5, o2 = 0;
for (var z = 0; z < B; z++) { o2++; if (z === 1) B = 3; }
ck("body_mutates_bound", o2);

// --- non-fastint / coercing bounds through the same path ---
var p2 = 0;
for (var a1 = 0; a1 < 3.5; a1++) { p2++; }
ck("float_bound", p2);

var q2 = 0;
for (var b1 = 0; b1 < "3"; b1++) { q2++; }
ck("string_bound", q2);

var r2 = 0;
for (var c1 = 0; c1 < NaN; c1++) { r2++; }
ck("nan_bound", r2);

// --- other loop forms must be unaffected ---
var s2 = 0, d1 = 0;
while (d1 < 4) { d1++; s2++; }
ck("while", s2);

var t2 = 0, e1 = 0;
do { e1++; t2++; } while (e1 < 4);
ck("dowhile", t2);

var u2 = 0;
for (var f1 = 10; f1 > 6; f1--) { u2++; }
ck("countdown", u2 + "/" + f1);

// --- for with empty/compound clauses ---
var v2 = 0;
for (var g1 = 0, h1 = 10; g1 < h1; g1++, h1--) { v2++; }
ck("two_counters", v2 + "/" + g1 + "/" + h1);

var w2 = 0, i1 = 0;
for (;;) { i1++; if (i1 >= 3) break; w2++; }
ck("empty_clauses", w2);

// --- throw from inside the loop unwinds past the preheader ---
var x2 = "none";
try { for (var j1 = 0; j1 < 5; j1++) { if (j1 === 2) throw new Error("stop"); } }
catch (err) { x2 = err.message + "@" + j1; }
ck("throw_in_body", x2);

// --- throwing valueOf in the condition itself ---
var y2 = "none", k1 = 0;
var thrower = { valueOf: function () { throw new Error("cond"); } };
try { for (k1 = 0; k1 < thrower; k1++) {} } catch (err2) { y2 = err2.message; }
ck("throw_in_cond", y2 + "/" + k1);

// --- loop inside a function (register-resident locals, different path) ---
function fn1() { var s = 0; for (var i2 = 0; i2 < 5; i2++) { s += i2; } return s; }
ck("fn_local_loop", fn1());

// --- closure captures the counter across iterations ---
var fns = [];
for (var l1 = 0; l1 < 3; l1++) { (function (n) { fns.push(function () { return n; }); })(l1); }
ck("closures", fns[0]() + "," + fns[1]() + "," + fns[2]());

// --- let-scoped counter (per-iteration binding, separate codegen path) ---
var m1 = 0;
for (let n1 = 0; n1 < 4; n1++) { m1++; }
ck("let_counter", m1);

var lets = [];
for (let o1 = 0; o1 < 3; o1++) { lets.push(function () { return o1; }); }
ck("let_closures", lets[0]() + "," + lets[1]() + "," + lets[2]());

// --- try/finally around and inside the loop (TRY's two-word slot nearby) ---
var p1 = 0;
for (var q1 = 0; q1 < 4; q1++) { try { if (q1 === 1) continue; p1++; } finally { p1 += 10; } }
ck("try_finally_continue", p1);

// NOTE: this currently prints 203, not the spec-correct 103 — `finally` runs
// twice when `break` exits a for-loop inside the try. That is a PRE-EXISTING
// bug (reproduced at 03d773bc, before any of this session's commits), not a
// preheader regression; it is recorded here so the value is pinned while the
// loop-rotation work happens around it.
var r1 = 0;
try { for (var s1 = 0; s1 < 4; s1++) { r1++; if (s1 === 2) break; } } finally { r1 += 100; }
ck("try_finally_break", r1);

// --- switch inside the loop body ---
var t1 = 0;
for (var u1 = 0; u1 < 5; u1++) {
  switch (u1) { case 1: continue; case 3: t1 += 10; break; default: t1++; }
}
ck("switch_body", t1);

print(out.join("\n"));
