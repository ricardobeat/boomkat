// Threaded paths for constructors, returns and global assignments.
//
// NEW_OBJ of a simple constructor, a constructor's return, a return from a
// frame with many heap registers, and the RESOLVEVAR / THROW_UNRESOLVED /
// PUTVAR_SNAP sequence of an assignment now stay in the threaded loop. Each
// must agree with the switch on what a binding or a construction yields.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// Simple constructors, including a reassigned prototype and missing args.
function Pair(a, b) { this.car = a; this.cdr = b; }
var list = null;
for (var i = 0; i < 50; i++) list = new Pair(i, list);
var sum = 0;
for (var p = list; p !== null; p = p.cdr) sum += p.car;
eq(sum, 1225, 'simple constructor chain');
eq(list instanceof Pair, true, 'instance of simple constructor');
Pair.prototype = { tag: 'new' };
var q = new Pair(1);
eq(q.tag + q.car + q.cdr, 'new1undefined', 'reassigned prototype and missing arg');
eq(Object.keys(new Pair(1, 2)).join(), 'car,cdr', 'property order');

// A constructor that returns an object, a primitive, or nothing.
function RetObj() { this.x = 1; return { y: 2 }; }
function RetPrim() { this.x = 3; return 42; }
function RetNone(v) { this.x = v; if (v > 100) return; this.y = v + 1; }
var r = 0;
for (var i = 0; i < 20; i++) {
    r += new RetObj().y + new RetPrim().x + new RetNone(i).y;
}
eq(r, 20 * 2 + 20 * 3 + 210, 'constructor return values');
eq(new RetNone(500).y, undefined, 'early return from constructor');

// A frame with many heap registers returns its value intact.
function wide(n) {
    var a = [n], b = [n], c = [n], d = [n], e = [n], f = [n], g = [n], h = [n];
    var i2 = [n], j = [n], k = [n], l = [n], m = [n], o = [n], p2 = [n], q2 = [n];
    var s = { a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i2, j: j, k: k, l: l, m: m, o: o, p: p2, q: q2 };
    return s.q[0] + s.a[0] + String(n);
}
var w = '';
for (var i = 0; i < 30; i++) w = wide(i);
eq(w, '5829', 'wide frame return');

// Global assignments of every value kind, read back.
var gNum = 0, gStr = '', gObj = null;
function assign(i) {
    gNum = gNum + i;
    gStr = gStr + String.fromCharCode(97 + (i % 26));
    gObj = { i: i, prev: gObj };
}
for (var i = 0; i < 100; i++) assign(i);
eq(gNum, 4950, 'global number assignment');
eq(gStr.length + gStr.slice(0, 3), '100abc', 'global string assignment');
eq(gObj.i + gObj.prev.i, 197, 'global object assignment');

// A const global keeps throwing, and a deleted global is recreated in
// sloppy code and reported in strict code.
const gConst = 1;
function setConst() { gConst = 2; }
var threw = 0;
for (var i = 0; i < 3; i++) { try { setConst(); } catch (e) { if (e instanceof TypeError) threw++; } }
eq(threw, 3, 'const global assignment throws');
globalThis.gGone = 1;
function setGone(v) { gGone = v; }
for (var i = 0; i < 5; i++) setGone(i);
delete globalThis.gGone;
setGone(9);
eq(globalThis.gGone, 9, 'sloppy assignment recreates deleted global');
function strictSet() { 'use strict'; gStrict = 1; }
globalThis.gStrict = 0;
for (var i = 0; i < 3; i++) strictSet();
delete globalThis.gStrict;
var refErr = false;
try { strictSet(); } catch (e) { refErr = e instanceof ReferenceError; }
eq(refErr, true, 'strict assignment to deleted global');

// A closure variable reached through RESOLVEVAR.
function counterBox() {
    var n = 0;
    return function () { n = n + 1; return n; };
}
var next = counterBox();
for (var i = 0; i < 9; i++) next();
eq(next(), 10, 'captured assignment');

print('threaded_frames_and_globals: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
