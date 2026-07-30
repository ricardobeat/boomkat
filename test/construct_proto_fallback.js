// [[Construct]] with a non-object .prototype must fall back to the intrinsic
// default prototype (OrdinaryCreateFromConstructor step 3: constructor.prototype
// only replaces intrinsicDefaultProto when it is an Object).
//
// Regression test for the NULL-prototype objects that
// `function F(){}; F.prototype = 42; new F()` used to produce, whose .toString
// was undefined.
//
// For ordinary (JS-defined) constructors the intrinsic default is
// %Object.prototype%.  For builtins constructed via a junk new.target the
// intrinsic default is that builtin's own prototype (%Error.prototype%,
// %Array.prototype%, ...), NOT %Object.prototype% — both are covered below.
// Expectations verified against node v24.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Every ordinary-constructor path below must produce an object whose
// [[Prototype]] is Object.prototype AND on which ordinary Object.prototype
// methods actually work (the original bug produced a null-prototype object,
// so `o.toString` was undefined rather than merely mis-parented).
function assertFallback(o, msg) {
    assert(Object.getPrototypeOf(o) === Object.prototype, msg + ": proto is Object.prototype");
    assert(typeof o.toString === "function", msg + ": inherits toString");
    assert(o.toString() === "[object Object]", msg + ": toString() works");
    assert(typeof o.hasOwnProperty === "function", msg + ": inherits hasOwnProperty");
    assert(o.hasOwnProperty("toString") === false, msg + ": hasOwnProperty() works");
    assert(typeof o.valueOf === "function", msg + ": inherits valueOf");
    assert(o.valueOf() === o, msg + ": valueOf() works");
}

// --- Plain `new` with every non-object .prototype value ---
var nonObjects = [
    ["number", 42],
    ["zero", 0],
    ["string", "nope"],
    ["empty string", ""],
    ["boolean true", true],
    ["boolean false", false],
    ["null", null],
    ["undefined", undefined],
    ["NaN", NaN]
];
for (var i = 0; i < nonObjects.length; i++) {
    var name = nonObjects[i][0];
    var F = function () {};
    F.prototype = nonObjects[i][1];
    assertFallback(new F(), "new F() with .prototype = " + name);
}

// The constructor body still runs and `this` is the fallback-proto object.
function WithBody() { this.tag = "body"; }
WithBody.prototype = 42;
var wb = new WithBody();
assert(wb.tag === "body", "constructor body runs on fallback object");
assertFallback(wb, "constructor with a body");

// --- Object .prototype values MUST be honoured, not overwritten ---
var realProto = { marker: "real" };
function G() {}
G.prototype = realProto;
var g = new G();
assert(Object.getPrototypeOf(g) === realProto, "object .prototype is honoured");
assert(g.marker === "real", "object .prototype members are inherited");

// A function is an object too, so it is a legal .prototype.
var fnProto = function tag() {};
fnProto.marker = "fn";
function H() {}
H.prototype = fnProto;
var h = new H();
assert(Object.getPrototypeOf(h) === fnProto, "function .prototype is honoured");
assert(h.marker === "fn", "function .prototype members are inherited");

// An array is an object too.
var arrProto = [1, 2, 3];
function I() {}
I.prototype = arrProto;
assert(Object.getPrototypeOf(new I()) === arrProto, "array .prototype is honoured");

// Object.create(null) as .prototype -> a genuinely null-prototype instance.
// This proves the fix did not simply force Object.prototype unconditionally.
var nullProto = Object.create(null);
function J() {}
J.prototype = nullProto;
var j = new J();
assert(Object.getPrototypeOf(j) === nullProto, "Object.create(null) .prototype is honoured");
assert(j.toString === undefined, "null-prototype chain really has no toString");

// --- Reflect.construct, target's .prototype non-object ---
function RT() {}
RT.prototype = 7;
assertFallback(Reflect.construct(RT, []), "Reflect.construct(target)");

// --- Reflect.construct with a distinct newTarget: newTarget.prototype decides ---
function Good() {}
Good.prototype = { marker: "good" };
function BadNT() {}
BadNT.prototype = "not-an-object";
// newTarget has a non-object .prototype -> fall back, even though the target's
// .prototype is a perfectly good object.
assertFallback(Reflect.construct(Good, [], BadNT), "Reflect.construct newTarget non-object");
// ...and the reverse: the target's .prototype is junk but newTarget's is fine,
// so the good one wins (newTarget, not target, supplies the prototype).
var rc = Reflect.construct(BadNT, [], Good);
assert(Object.getPrototypeOf(rc) === Good.prototype, "Reflect.construct uses newTarget.prototype");
assert(rc.marker === "good", "Reflect.construct newTarget members inherited");

// --- Bound functions: the bound target's .prototype is what matters ---
function B() {}
B.prototype = 123;
var Bound = B.bind(null);
assertFallback(new Bound(), "new (bound function)");

// Bound-of-bound must unwrap all the way down to B.
var Bound2 = Bound.bind(null);
var Bound3 = Bound2.bind(null);
assertFallback(new Bound3(), "new (bound-of-bound-of-bound)");

// A bound function has no own .prototype; assigning one must not change the
// result, because [[Construct]] forwards to the bound target.
var Bound4 = B.bind(null);
Bound4.prototype = { marker: "ignored" };
var b4 = new Bound4();
assert(b4.marker === undefined, "bound function's own .prototype is ignored");
assertFallback(b4, "bound function with own .prototype");

// Bound function whose target has a good .prototype still honours it.
function BG() {}
BG.prototype = { marker: "bg" };
var BoundGood = BG.bind(null).bind(null);
assert(Object.getPrototypeOf(new BoundGood()) === BG.prototype, "bound target object .prototype honoured");
assert(new BoundGood().marker === "bg", "bound target proto members inherited");

// Reflect.construct on a bound function.
assertFallback(Reflect.construct(Bound, []), "Reflect.construct(bound)");
// Bound function as newTarget: its [[Construct]]-relevant prototype is the
// target's, which here is the number 123 -> fall back.
assertFallback(Reflect.construct(Good, [], Bound), "Reflect.construct newTarget = bound(junk proto)");

// --- Class constructors ---
// A class's .prototype is non-writable AND non-configurable, so it cannot be
// replaced in-place; drive the junk-prototype path through new.target instead.
function JunkNT() {}
JunkNT.prototype = 5;

class C { constructor() { this.tag = "c"; } }
var c = Reflect.construct(C, [], JunkNT);
assert(c.tag === "c", "class body still runs");
assertFallback(c, "class constructed with non-object-proto new.target");

// A well-formed class is unaffected.
var cOk = new C();
assert(Object.getPrototypeOf(cOk) === C.prototype, "well-formed class .prototype honoured");

// --- Derived class via super(): new.target propagates to the base allocation ---
class Base { constructor() { this.base = 1; } }
class Derived extends Base { constructor() { super(); this.derived = 2; } }
var d = Reflect.construct(Derived, [], JunkNT);
assert(d.base === 1, "derived: base constructor ran");
assert(d.derived === 2, "derived: derived constructor ran");
assertFallback(d, "derived class with non-object-proto new.target");

// Implicit derived constructor (no explicit constructor body) takes the same path.
class Derived2 extends Base {}
var d2 = Reflect.construct(Derived2, [], JunkNT);
assert(d2.base === 1, "implicit derived: base constructor ran");
assertFallback(d2, "implicit derived class with non-object-proto new.target");

// Three levels deep.
class Derived3 extends Derived { constructor() { super(); this.third = 3; } }
var d3 = Reflect.construct(Derived3, [], JunkNT);
assert(d3.base === 1 && d3.derived === 2 && d3.third === 3, "3-level derived: all bodies ran");
assertFallback(d3, "3-level derived class with non-object-proto new.target");

// Derived class with a good .prototype is unaffected.
var dOk = new Derived();
assert(Object.getPrototypeOf(dOk) === Derived.prototype, "derived class good .prototype honoured");

// Reflect.construct(Base, [], BadNT) — the base's OrdinaryCreateFromConstructor
// reads BadNT.prototype, which is a string, so it falls back.
var rb = Reflect.construct(Base, [], BadNT);
assert(rb.base === 1, "Reflect.construct(Base,...) ran base body");
assertFallback(rb, "Reflect.construct(Base, [], non-object-proto newTarget)");

// --- Builtin subclassing via new.target ---
// For builtins the intrinsic default prototype is the builtin's OWN prototype,
// not %Object.prototype% — a junk new.target must fall back to %Error.prototype%
// / %Array.prototype%.  (Confirmed against node v24.)
var be = Reflect.construct(Error, ["boom"], JunkNT);
assert(Object.getPrototypeOf(be) === Error.prototype, "Error via junk newTarget -> Error.prototype");
assert(be.message === "boom", "Error via junk newTarget still gets .message");
assert(typeof be.toString === "function", "Error via junk newTarget inherits toString");

var ba = Reflect.construct(Array, [1, 2, 3], JunkNT);
assert(Object.getPrototypeOf(ba) === Array.prototype, "Array via junk newTarget -> Array.prototype");
assert(ba.length === 3, "Array via junk newTarget still has length");

// An Error subclass built with a junk new.target: the subclass's implicit
// derived constructor forwards new.target to Error, so the intrinsic default
// %Error.prototype% is used.
class MyErr extends Error {}
var me = Reflect.construct(MyErr, ["sub"], JunkNT);
assert(Object.getPrototypeOf(me) === Error.prototype, "Error subclass via junk newTarget -> Error.prototype");
assert(me.message === "sub", "Error subclass via junk newTarget keeps .message");

// And the well-behaved subclass cases still work.
var meOk = new MyErr("ok");
assert(Object.getPrototypeOf(meOk) === MyErr.prototype, "well-formed Error subclass honoured");
assert(meOk instanceof Error, "well-formed Error subclass instanceof Error");

class MyArr extends Array {}
var ma = new MyArr();
assert(Object.getPrototypeOf(ma) === MyArr.prototype, "well-formed Array subclass honoured");

print("construct_proto_fallback: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
