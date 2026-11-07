// INSTANCEOF answered from the site's cache after warmup, and every way the cached
// facts can stop holding: bound functions, Symbol.hasInstance installed later,
// proxies on either side, primitives and lightfuncs on the left, a non-callable
// or non-object right operand, a reassigned or accessor `prototype`, a changed
// prototype link, deep chains, getters on the prototype, a proxy mid-chain.
var out = [];
function check(label, v) { out.push(label + "=" + v); }

function Pair(a) { this.a = a; }
function Other() {}
function Sub() {}
Sub.prototype = Object.create(Pair.prototype);
function isPair(x) { return x instanceof Pair; }
function isCtor(x, C) { return x instanceof C; }
function tryCtor(x, C) {
    try { return x instanceof C; } catch (e) { return e.constructor.name; }
}

var p = new Pair(1), o = new Other(), s = new Sub();
var prims = [undefined, null, 0, 1.5, "str", true, Symbol("s"), 10n, JSON.parse];
for (var i = 0; i < 3000; i++) {
    isPair(p); isPair(o); isPair(s); isPair(i); isPair("x"); isPair(null);
    isCtor(p, Pair); isCtor(s, Pair);
}
check("warm", [isPair(p), isPair(o), isPair(s), isPair(1), isPair(null), isPair("x")].join());
check("prims", prims.map(function (v) { return isPair(v); }).join());
check("lightfunc", [JSON.parse instanceof Function, JSON.parse instanceof Object, isCtor(JSON.parse, Function), isCtor(JSON.parse, Pair)].join());
check("proto-self", isPair(Pair.prototype) + "," + isCtor(Pair.prototype, Pair));
check("functions", [isCtor(Pair, Function), isCtor(Pair, Object), isCtor(Pair, Pair)].join());

// deep chains
var chain = Object.create(Pair.prototype);
for (var d = 0; d < 400; d++) chain = Object.create(chain);
function deep(x) { return x instanceof Pair; }
for (var i = 0; i < 2000; i++) deep(p);
check("deep", deep(chain) + "," + deep(Object.create(null)) + "," + deep({}));

// non-callable and non-object right operand
for (var i = 0; i < 200; i++) tryCtor(p, Pair);
check("rhs", [tryCtor(p, {}), tryCtor(p, 1), tryCtor(p, null), tryCtor(p, undefined), tryCtor(p, "s"), tryCtor(p, Math)].join());
var fake = Object.create(Function.prototype);
Object.defineProperty(fake, "prototype", { value: Pair.prototype });
check("fake-callable", tryCtor(p, fake));

// bound functions
var BP = Pair.bind(null, 1);
for (var i = 0; i < 300; i++) tryCtor(p, BP);
check("bound", [tryCtor(p, BP), tryCtor(new BP(), Pair), tryCtor(new BP(), BP), tryCtor(o, BP)].join());

// prototype reassigned after the site cached the slot
function Mut() {}
var m1 = new Mut();
for (var i = 0; i < 500; i++) tryCtor(m1, Mut);
check("mut-before", tryCtor(m1, Mut));
var old = Mut.prototype;
Mut.prototype = { x: 1 };
check("mut-after", tryCtor(m1, Mut) + "," + tryCtor(Object.create(Mut.prototype), Mut));
Mut.prototype = 5;
check("mut-nonobject", tryCtor(m1, Mut));
Mut.prototype = old;
check("mut-restored", tryCtor(m1, Mut));

// prototype of the left changed
function Lft() {}
var l1 = new Lft();
for (var i = 0; i < 500; i++) tryCtor(l1, Pair);
check("setproto-before", tryCtor(l1, Pair));
Object.setPrototypeOf(l1, Pair.prototype);
check("setproto-after", tryCtor(l1, Pair));
Pair.prototype.__proto__ = null;
check("chain-cut", tryCtor(s, Pair) + "," + tryCtor(l1, Pair));
Object.setPrototypeOf(Pair.prototype, Object.prototype);

// Symbol.hasInstance installed after warmup, on the function, and on Function.prototype's descendants
function Hi() {}
var h1 = new Hi();
for (var i = 0; i < 2000; i++) tryCtor(h1, Hi);
check("hi-before", tryCtor(h1, Hi));
Object.defineProperty(Hi, Symbol.hasInstance, { value: function (v) { return v === 42; }, configurable: true });
check("hi-own", tryCtor(h1, Hi) + "," + tryCtor(42, Hi));
delete Hi[Symbol.hasInstance];
check("hi-deleted", tryCtor(h1, Hi) + "," + tryCtor(42, Hi));
class Cls { static [Symbol.hasInstance](v) { return v === "cls"; } }
for (var i = 0; i < 500; i++) tryCtor(p, Cls);
check("static-hi", tryCtor("cls", Cls) + "," + tryCtor(new Cls(), Cls));
// a function whose prototype link moves to a function carrying @@hasInstance
function Moved() {}
var mv = new Moved();
for (var i = 0; i < 2000; i++) tryCtor(mv, Moved);
var holder = function () {};
Object.defineProperty(holder, Symbol.hasInstance, { value: function () { return "yes"; } });
Object.setPrototypeOf(Moved, holder);
check("moved-proto", tryCtor(mv, Moved) + "," + tryCtor(1, Moved));
// getter @@hasInstance, getter prototype
function Acc() {}
var a1 = new Acc();
for (var i = 0; i < 2000; i++) tryCtor(a1, Acc);
var calls = 0;
Object.defineProperty(Acc, Symbol.hasInstance, { get: function () { calls++; return function () { return false; }; }, configurable: true });
check("hi-getter", tryCtor(a1, Acc) + "," + calls);
delete Acc[Symbol.hasInstance];
function Gp() {}
var g1 = new Gp(), gcalls = 0;
for (var i = 0; i < 2000; i++) tryCtor(g1, Gp);
var Gp2 = () => {};
Object.defineProperty(Gp2, "prototype", { get: function () { gcalls++; return Pair.prototype; } });
check("proto-getter", tryCtor(p, Gp2) + "," + tryCtor(o, Gp2) + "," + gcalls);
// getter on the prototype object itself is not run by instanceof
var Q = function () {};
Object.defineProperty(Q.prototype, "boom", { get: function () { throw new Error("no"); } });
var q1 = new Q();
for (var i = 0; i < 500; i++) tryCtor(q1, Q);
check("proto-obj-getter", tryCtor(q1, Q) + "," + tryCtor(o, Q));

// proxies
var PP = new Proxy(Pair, {});
for (var i = 0; i < 300; i++) tryCtor(p, PP);
check("proxy-rhs", tryCtor(p, PP) + "," + tryCtor(o, PP));
var trapped = [];
var PT = new Proxy(Pair, { get: function (t, k) { trapped.push(String(k)); return t[k]; } });
check("proxy-rhs-trap", tryCtor(p, PT) + "," + trapped.join("|"));
var PL = new Proxy(p, {});
var gp = [];
var PL2 = new Proxy(p, { getPrototypeOf: function (t) { gp.push("g"); return Pair.prototype; } });
for (var i = 0; i < 300; i++) isPair(p);
check("proxy-lhs", isPair(PL) + "," + isPair(PL2) + "," + gp.length);
var mid = new Proxy(Pair.prototype, { getPrototypeOf: function () { gp.push("m"); return Object.prototype; } });
var viaMid = Object.create(mid);
check("proxy-mid", isPair(viaMid) + "," + isCtor(viaMid, Object) + "," + gp.join(""));
var rev = Proxy.revocable(function () {}, {});
rev.revoke();
check("revoked", tryCtor(p, rev.proxy));

// a callable that is not a function object and a class with static members
class A {}
class B extends A {}
var b = new B();
for (var i = 0; i < 2000; i++) { isCtor(b, A); isCtor(b, B); }
check("classes", [isCtor(b, A), isCtor(b, B), isCtor(new A(), B), isCtor(A, Function)].join());

// one site, many right operands (the cache thrashes)
var ctors = [Pair, Other, Sub, A, B, Function, Object, Array, Date, Hi, BP];
var objs = [p, o, s, b, [], new Date(), {}, function () {}];
var tally = 0;
for (var i = 0; i < 4000; i++) {
    var C = ctors[i % ctors.length], O = objs[(i >> 1) % objs.length];
    if (tryCtor(O, C) === true) tally++;
}
check("poly", tally);
for (var i = 0; i < ctors.length; i++) check("m" + i, objs.map(function (v) { return tryCtor(v, ctors[i]); }).join());

// objects in dictionary mode and with many properties on the right operand
function Dict() {}
for (var k = 0; k < 200; k++) Dict["p" + k] = k;
var dobj = new Dict();
for (var i = 0; i < 500; i++) tryCtor(dobj, Dict);
Dict[Symbol.hasInstance] = undefined;
check("dict", tryCtor(dobj, Dict));
delete Dict.p5;
Object.defineProperty(Dict, Symbol.hasInstance, { value: function () { return "dyn"; }, configurable: true });
check("dict-hi", tryCtor(dobj, Dict));

// the result register aliasing an operand
function alias(x, C) { x = x instanceof C; return x; }
function alias2(x, C) { C = x instanceof C; return C; }
for (var i = 0; i < 1000; i++) { alias(p, Pair); alias2(p, Pair); }
check("alias", [alias(p, Pair), alias(o, Pair), alias2(p, Pair), alias2(1, Pair)].join());

// used as a condition and in a loop
function count(list, C) { var n = 0; for (var i = 0; i < list.length; i++) if (list[i] instanceof C) n++; return n; }
for (var i = 0; i < 500; i++) count(objs, Pair);
check("count", count(objs, Pair) + "," + count(objs, Object) + "," + count(objs, Function));

// exceptions from a throwing getter during an inlined site
function thrower() {}
var t1 = new thrower();
for (var i = 0; i < 2000; i++) tryCtor(t1, thrower);
Object.defineProperty(thrower, Symbol.hasInstance, { get: function () { throw new RangeError("hi"); }, configurable: true });
check("throw", tryCtor(t1, thrower));

print(out.join("\n"));
