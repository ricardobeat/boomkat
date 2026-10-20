// A member chain nested inside parentheses must free its call receiver.
//
// `inside_parens` lets `(a.b)()` keep `a` as the receiver for the call that
// follows the parenthesized chain. It used to stay set for the whole subtree,
// so `this.s` inside `(this.s << bs)` kept its receiver register pending. The
// next chain freed that stale register after allocating its own result in the
// same slot, and `this.t - 1` loaded the 1 over `this.t`, computing 0. Octane's
// Crypto (BigInteger lShiftTo) hung and Gameboy failed its state check.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print('FAIL: ' + msg); }
}

function eq(actual, expected, msg) {
    assert(actual === expected, msg + ' (got ' + actual + ', want ' + expected + ')');
}

var o = { s: 0, t: 5, x: 1, f: function () { return this.x; } };

function shift_then_member(n) { var bs = 1; var ds = Math.floor(n), c = (this.s << bs); return this.t - 1; }
eq(shift_then_member.call(o, 3), 4, 'parenthesized this.s << bs before this.t - 1');

function add_then_member(n) { var bs = 1; var ds = Math.floor(n), c = (this.s + bs); return this.t - 1; }
eq(add_then_member.call(o, 3), 4, 'parenthesized this.s + bs before this.t - 1');

function obj_then_member(p) { var c = (p.s | 2) & 255; return p.t - 1; }
eq(obj_then_member(o), 4, 'parenthesized p.s before p.t - 1');

// The BigInteger left shift from Crypto, which looped once instead of five times.
var BI_DB = 28, BI_DM = (1 << 28) - 1;
function lshift(n, r) {
    var this_array = this.array, r_array = r.array;
    var bs = n % BI_DB, cbs = BI_DB - bs, bm = (1 << cbs) - 1;
    var ds = Math.floor(n / BI_DB), c = (this.s << bs) & BI_DM, i;
    for (i = this.t - 1; i >= 0; --i) {
        r_array[i + ds + 1] = (this_array[i] >> cbs) | c;
        c = (this_array[i] & bm) << bs;
    }
    for (i = ds - 1; i >= 0; --i) r_array[i] = 0;
    r_array[ds] = c;
    r.t = this.t + ds + 1;
}
var big = { array: [162254319, 36984440, 198045441, 72775834, 291], t: 5, s: 0 };
var out = { array: [], t: 0 };
lshift.call(big, 37, out);
eq(out.array.join(','), '0,127655424,145551669,199098950,217134457,149130,0', 'BigInteger lShiftTo');

// The receiver must still survive for a call on the parenthesized chain itself.
eq((o.f)(), 1, '(o.f)() keeps o as this');
eq((o['f'])(), 1, '(o["f"])() keeps o as this');
eq(((o.f))(), 1, '((o.f))() keeps o as this');

print('paren_member_receiver: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
