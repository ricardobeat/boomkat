// Fusion liveness: a NOP pad must never be read as a write of r0.
//
// Earlier fusions (GETPROPC, PUTPROPC) pad with make_abc(NOP, 0, 0, 0). NOP has
// format NONE, so the dead-after-liveness scans (fusion_reg_live_from and its
// sibling in compiler/fusion.c3) skipped the read check and then hit the
// generic "A == reg means overwritten" kill, treating every NOP as a write of
// r0. In a function whose `this` sits in r0, `this.f += 1` compiles to
//
//     LDTHIS r0; GETPROPC r2 = r0, f; ADDI r2; NOP; PUTPROPC r0 = r2, f
//
// and the scan stopped at the NOP, so LDTHIS + GETPROPC fused into GETTHISC and
// PUTPROPC read an r0 that was never loaded: "Cannot set properties of
// undefined". Octane's Typescript and Gameboy both failed on this shape.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
    assert(actual === expected, msg + ' (got ' + actual + ', want ' + expected + ')');
}

function add_one() { this.f += 1; return this.f; }
eq(add_one.call({ f: 1 }), 2, 'this.f += 1 through call');

var o = { f: 0, a: function () { this.f |= 4; } };
o.a();
eq(o.f, 4, 'this.f |= 4 in a method');

var m = { f: 3, a() { this.f -= 1; } };
m.a();
eq(m.f, 2, 'this.f -= 1 in a shorthand method');

// The Octane shapes: a constructor field updated from prototype methods,
// one calling the other, hot enough to reach the inline caches.
function T() { this.f = 0; this.q = 1; }
T.prototype.a = function () { this.f |= 4; };
T.prototype.b = function () { this.f += this.q; this.a(); };
var t = new T();
for (var i = 0; i < 1000; i++) { t.b(); }
eq(t.f, 2004, 'prototype methods updating this.f in a loop');

// Several compound updates leave several NOP pads behind.
function multi() { this.x += 1; this.y *= 2; this.x <<= 1; return this.x + ':' + this.y; }
eq(multi.call({ x: 1, y: 3 }), '4:6', 'chained compound updates on this');

print('fusion_liveness_nop_r0: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
