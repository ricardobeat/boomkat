// A construct call's `this` slot must be owned by the calling frame.
//
// NEW_OBJ stores the new object in the caller's callee_reg + 1 with a
// reference (the constructor frame's `this` slot) but did not raise the
// caller's heap_reg_count, so the caller's pop never released it. The
// reference leaked, the tracing collector freed the object once nothing else
// reached it, and a later root scan over the valstack window read the stale
// pointer bits: a use-after-free in FixedBlockPool.alloc during Octane's
// RayTrace. SUPER_CALL's base-constructor `this` and the getter-call helper
// had the same gap. The read depends on stack layout; the unswept slot itself
// shows up deterministically when sweep_callee_regs runs assert_frame_clear
// under HEAP_VERIFY, as in `make` of boomkat_threaded_asan with -D HEAP_VERIFY.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function Point(x, y) { if (x < 0) { throw new Error('neg'); } this.x = x; this.y = y; }
function Wrapper() { Point.apply(this, arguments); }

function make(n) {
    var a = 0, b = 1, c = 2, d = 3, e = 4, f = 5, g = 6, h = 7;
    for (var i = 0; i < n; i++) { new Point(i, a + b + c + d + e + f + g + h); new Wrapper(i, i); }
    return n;
}
function deep(n, depth) { return depth == 0 ? make(n) : deep(n, depth - 1) + 0; }

class Base { constructor(v) { this.v = v; } }
class Derived extends Base { constructor(v) { super(v); this.w = v; } }

var o = { get p() { return new Point(1, 2).x; } };
var sum = 0;
for (var k = 0; k < 200; k++) {
    sum += make(20) + deep(5, 8) + new Derived(k).w + o.p;
    var junk = [];
    for (var j = 0; j < 50; j++) junk.push({ j: j });
}
assert(sum === 200 * 25 + 199 * 100 + 200, 'constructed values survive collection (' + sum + ')');

print('gc_construct_this_slot: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
