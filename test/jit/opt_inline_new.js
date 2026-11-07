// `new C(...)` inlined by the optimizing tier: the object allocated in the caller, the constructor's
// stores as property adds, in the function's own body and inside inlined methods (one and two deep).
// Objects with one to six fields, values of every kind, constructors that return primitives and
// objects, prototypes replaced or given a setter or a readonly property after warmup, class and
// function constructors, a site that sees a second constructor, and allocation pressure.
// scripts/opt_exit_check.sh forces an exit at every point of the bodies (inline/, inline2/), which
// publishes the constructor's frame with the object as its `this`.
var out = [];
function show(label, v) { out.push(label + "=" + v); }
function keys(o) { return Object.keys(o).join(","); }

function One(a) { this.a = a; }
function Two(a, b) { this.a = a; this.b = b; }
function Three(a, b, c) { this.x = a; this.y = b; this.z = c; }
function Four(a, b, c, d) { this.a = a; this.b = b; this.c = c; this.d = d; }
function Six(a, b) { this.p0 = a; this.p1 = b; this.p2 = a + 1; this.p3 = b + 1; this.p4 = a * 2; this.p5 = b * 2; }
function Prim(a) { this.a = a; return 7; }
function Obj(a) { this.a = a; return { other: a }; }
function Mixed(a, b) { this.a = a; this.s = b; this.o = { k: a }; }
class K { constructor(a, b) { this.a = a; this.b = b; } sum() { return this.a + this.b; } }

Three.prototype.add = function (w) { return new Three(this.x + w.x, this.y + w.y, this.z + w.z); };
Three.prototype.scale = function (k) { return new Three(this.x * k, this.y * k, this.z * k); };
Three.prototype.mid = function (w) { return this.add(w).scale(0.5); };
Three.prototype.dot = function (w) { return this.x * w.x + this.y * w.y + this.z * w.z; };

// Each constructor runs before anything tiers up.
new One(1); new Two(1, 2); new Three(1, 2, 3); new Four(1, 2, 3, 4); new Six(1, 2); new Prim(1); new Obj(1);
new Mixed(1, "s"); new K(1, 2);

function own(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o1 = new One(i);
        var o2 = new Two(i, 0.5);
        var o4 = new Four(i, i + 1, i + 2, i + 3);
        var o6 = new Six(i, 3);
        s += o1.a + o2.a + o2.b + o4.d + o6.p5 + o6.p2;
    }
    return s;
}
function nested(n) {
    var a = new Three(1, 2, 3), b = new Three(0.5, 1.5, 2.5), s = 0;
    for (var i = 0; i < n; i++) {
        var c = a.add(b);
        var m = a.mid(b);
        s += c.x + c.y + c.z + m.dot(b) + i;
    }
    return s;
}
function returns(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Prim(i);
        var q = new Obj(i);
        s += p.a + q.other + (q.a === undefined ? 1 : 0) + (p instanceof Prim ? 1 : 0) + (q instanceof Obj ? 0 : 1);
    }
    return s;
}
function classes(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var k = new K(i, 2); s += k.sum() + k.a; }
    return s;
}
function mixed(n, v) {
    var s = 0, last;
    for (var i = 0; i < n; i++) { last = new Mixed(i, v); s += last.a + last.o.k; }
    return s + ":" + keys(last) + ":" + typeof last.s;
}
function generic(C, n) {
    var s = 0, last;
    for (var i = 0; i < n; i++) { last = new C(i, 1); s += last.a; }
    return s + ":" + keys(last);
}

for (var r = 0; r < 6; r++) {
    show("own" + r, own(2000));
    show("nested" + r, nested(2000));
    show("returns" + r, returns(2000));
    show("classes" + r, classes(2000));
    show("mixed" + r, mixed(500, r % 2 ? "str" + r : { r: r }));
}
// Values of every kind in the fields, and the shapes they make.
var vals = [1, 2.5, "s", { k: 1 }, null, undefined, true, -0, 2 ** 40, [1]];
for (var r = 0; r < 4; r++) {
    var bad = 0;
    for (var i = 0; i < 3000; i++) {
        var v = vals[i % vals.length], t = new Two(v, i);
        if (!Object.is(t.a, v) || t.b !== i || keys(t) !== "a,b") bad++;
    }
    show("kinds" + r, bad);
}
// A site that sees a second constructor stays a call.
show("generic1", generic(One, 2000));
show("generic2", generic(Two, 2000));
show("generic3", generic(One, 2000));

// The prototype replaced after warmup: new objects take the new one.
function Pt(x, y) { this.x = x; this.y = y; }
Pt.prototype.len = function () { return this.x + this.y; };
function pts(n) { var s = 0; for (var i = 0; i < n; i++) { var p = new Pt(i, 1); s += p.len(); } return s; }
show("pts1", pts(3000));
Pt.prototype = { len: function () { return this.x * 2; } };
show("pts2", pts(3000));
show("pts proto", Object.getPrototypeOf(new Pt(1, 2)) === Pt.prototype);
// A setter on the chain for a key the constructor adds: the setter runs and nothing is added.
var setlog = [];
Object.defineProperty(Pt.prototype, "y", { set(v) { setlog.push(v); }, get() { return 100; }, configurable: true });
show("pts3", pts(300));
show("setter", setlog.length + " " + new Pt(1, 2).hasOwnProperty("y"));
delete Pt.prototype.y;
show("pts4", pts(3000));
// A readonly property on the chain: a sloppy constructor's add is dropped, a class's throws.
Object.defineProperty(Pt.prototype, "x", { value: 5, writable: false, configurable: true });
show("pts5", pts(300));
show("readonly", new Pt(9, 1).x + " " + new Pt(9, 1).hasOwnProperty("x"));
delete Pt.prototype.x;
show("pts6", pts(3000));
Object.defineProperty(K.prototype, "b", { value: 0, writable: false, configurable: true });
try { classes(10); show("class readonly", "no throw"); } catch (e) { show("class readonly", e.constructor.name); }
delete K.prototype.b;
show("classes again", classes(2000));
// The constructor rebound to a function that is not constructable.
var NC = One;
function viaVar(n) { var s = 0; for (var i = 0; i < n; i++) s += new NC(i).a; return s; }
show("viavar1", viaVar(3000));
NC = { m() { return 1; } }.m;
try { viaVar(10); show("method", "no throw"); } catch (e) { show("method", e.constructor.name); }
NC = () => 1;
try { viaVar(10); show("arrow", "no throw"); } catch (e) { show("arrow", e.constructor.name); }
NC = Two;
show("viavar2", viaVar(3000));

// Allocation pressure: many objects in the optimized caller, some of them kept.
var keep = [];
function churn(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = new Mixed(i, "v" + i);
        var t = new Three(i, i + 0.5, -i).add(new Three(1, 1, 1));
        if (i % 97 === 0) keep.push(o, t);
        s += o.o.k + t.x;
    }
    return s;
}
for (var r = 0; r < 20; r++) show("churn" + r, churn(5000));
var kbad = 0;
for (var i = 0; i < keep.length; i += 2) {
    var o = keep[i], t = keep[i + 1];
    if (o.s !== "v" + o.a || o.o.k !== o.a || t.y !== o.a + 1.5 || t.z !== 1 - o.a) kbad++;
}
show("kept", keep.length + " " + kbad);
print(out.join("\n"));
