// Store fusion across calls and GETTHISC.
//
// PUTPROPC and PUTTHISC fuse a key or `this` load with a store that follows
// the right-hand side. The gap scan used to stop at a GETTHISC or a call, and
// the liveness scan read LDREG's unused C field and a CALL's argument count as
// reads of a register, so `this.a = this.b.f()` kept its LDTHIS and computed
// PUTPROP. Calls in the gap are now crossed when the held register sits below
// the call window, which the callee's frame cannot reach.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function Node(id, next) { this.id = id; this.next = next; }
Node.prototype.step = function () { return this.next; };
Node.prototype.held = function () { return (this.id & 1) != 0; };

function Walker(list) { this.cur = null; this.list = list; this.seen = 0; this.last = -1; }
Walker.prototype.walk = function () {
    this.cur = this.list;
    while (this.cur != null) {
        if (this.cur.held()) {
            this.cur = this.cur.next;
        } else {
            this.last = this.cur.id;
            this.cur = this.cur.step();
        }
        this.seen = this.seen + 1;
    }
    return this.seen;
};

var list = null;
for (var i = 9; i >= 0; i--) list = new Node(i, list);
var w = new Walker(list);
eq(w.walk(), 10, 'every node visited');
eq(w.last, 8, 'last unheld id');
eq(w.cur, null, 'walk ends on null');

// A callee with many registers runs over the caller's window above the call;
// the held `this` and key must stay below it.
function deep(a) {
    var b = a + 1, c = b + 1, d = c + 1, e = d + 1, f = e + 1, g = f + 1;
    return [a, b, c, d, e, f, g].join('');
}
function Box() { this.v = 0; }
Box.prototype.fill = function (x) { this.v = deep(x); this['k' + x] = deep(x + 1); return this; };
var box = new Box().fill(1);
eq(box.v, '1234567', 'PUTTHISC after a call');
eq(box.k1, '2345678', 'computed store after a call');

// The key constant of a plain-object store is loaded before a call in the value.
var out = {};
function put(o) { o.name = deep(3); o.other = String(deep(4)).length; return o; }
put(out);
eq(out.name, '3456789', 'PUTPROPC after a call');
eq(out.other, 8, 'PUTPROPC after nested calls');

print('fusion_gap_calls: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
