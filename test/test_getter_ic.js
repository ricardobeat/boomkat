// Accessor reads through a warm inline cache, and the fused this.name forms.
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }

class P {
    constructor(x) { this.x = x; this.tag = "t" + x; }
    get double() { return this.x * 2; }
    get label() { return this.tag + "!"; }
    get self() { return this; }
    get twice() { return this.double + this.double; }
    set double(v) { this.x = v / 2; }
}
function sumDoubles(o, n) { var s = 0; for (var i = 0; i < n; i++) s += o.double; return s; }

var p = new P(5);
assertEq(sumDoubles(p, 100), 1000, "warm getter");
assertEq(p.label, "t5!", "string result");
assertEq(p.self, p, "receiver result");
assertEq(p.twice, 20, "nested getter");

// Redefining the getter on the prototype takes effect at a warm site.
Object.defineProperty(P.prototype, "double", { get: function () { return -1; }, configurable: true });
assertEq(sumDoubles(p, 10), -10, "replaced getter");
// A data property replaces the accessor.
Object.defineProperty(P.prototype, "double", { value: 7, configurable: true, writable: true });
assertEq(sumDoubles(p, 10), 70, "accessor became data");
// An own property shadows it.
Object.defineProperty(P.prototype, "double", { get: function () { return this.x; }, configurable: true });
assertEq(sumDoubles(p, 10), 50, "restored getter");
p.double = 3;   // no setter now: ignored in sloppy code
Object.defineProperty(p, "double", { value: 100, configurable: true });
assertEq(sumDoubles(p, 10), 1000, "own shadow");
delete p.double;
assertEq(sumDoubles(p, 10), 50, "shadow removed");
// Another receiver with the same shape reads its own state.
var q = new P(8);
assertEq(sumDoubles(q, 10), 80, "second receiver");
assertEq(sumDoubles(p, 10), 50, "first receiver again");
// A different prototype behind the same shape.
var r = new P(1);
Object.setPrototypeOf(r, { get double() { return "other"; } });
assertEq(r.double, "other", "setPrototypeOf");

// A getter that throws unwinds through the caller's frame.
var thrower = { get boom() { throw new RangeError("boom"); } };
function readBoom(o) { return o.boom; }
for (var i = 0; i < 3; i++) {
    var caught = null;
    try { readBoom(thrower); } catch (e) { caught = e; }
    assertEq(caught instanceof RangeError, true, "throw " + i);
}

// A getter that deletes its own accessor.
var selfDel = { n: 0, get once() { delete this.once; return 1; } };
function readOnce(o) { return o.once; }
assertEq(readOnce(selfDel), 1, "self delete");
assertEq(readOnce(selfDel), undefined, "after delete");

// Getters across garbage collection keep their results alive.
class Box { constructor(i) { this.i = i; } get text() { return "item-" + this.i; } get obj() { return { i: this.i }; } }
var keep = [];
for (var k = 0; k < 3000; k++) { var b = new Box(k); keep.push(b.text, b.obj); }
assertEq(keep[5999].i, 2999, "kept object");
assertEq(keep[0], "item-0", "kept string");

// Recursion through a getter.
var depth = { get down() { return this.n > 0 ? (this.n--, this.down + 1) : 0; }, n: 50 };
assertEq(depth.down, 50, "recursive getter");

// this.name forms.
function Counter() { this.a = 1; this.b = this.a + 1; this.c = this.a + this.b; }
Counter.prototype.sum = function () { return this.a + this.b + this.c; };
assertEq(new Counter().sum(), 6, "this reads and writes");
var strictThis = (function () { "use strict"; return function () { return this.length; }; })();
assertEq(strictThis.call("abcd"), 4, "primitive this");
assertEq(strictThis.call([1, 2]), 2, "array this");
class A { constructor() { this.v = 1; } }
class B extends A {
    constructor() { super(); this.w = this.v + 1; }
}
assertEq(new B().w, 2, "derived this");
class C extends A {
    constructor() {
        var read = function () { return 0; };
        try { this.z = read(); } catch (e) { var tdz = e instanceof ReferenceError; }
        super();
        this.ok = tdz;
    }
}
assertEq(new C().ok, true, "this before super");
class D extends A {
    constructor() {
        var setup = () => { super(); return 5; };
        this.q = setup();
    }
}
var dthrew = false;
try { new D(); } catch (e) { dthrew = e instanceof ReferenceError; }
assertEq(dthrew, true, "this.q = (super via arrow) reads this first");
print("ok");
