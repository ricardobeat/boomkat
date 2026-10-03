// A store under a computed (not yet interned) key must keep the full [[Set]]
// semantics when the threaded fast path declines it.
function assertEq(a, b, msg) { if (a !== b) throw new Error(msg + ": " + a + " !== " + b); }
function key(prefix, i) { return prefix + i; }

// New keys, then updates of the same keys.
var m = {};
for (var i = 0; i < 300; i++) m[key("k", i)] = i;
for (var i = 0; i < 300; i++) m[key("k", i)] += 1;
assertEq(Object.keys(m).length, 300, "key count");
assertEq(m.k0, 1, "first");
assertEq(m.k299, 300, "last");

// Array-index keys on a plain object keep their ordering semantics.
var idx = {};
idx[key("b", "")] = 1;
for (var i = 5; i >= 0; i--) idx[key("", i)] = i;
assertEq(Object.keys(idx).join(","), "0,1,2,3,4,5,b", "index keys first, ascending");

// An inherited accessor runs its setter instead of creating an own property.
var seen = [];
Object.defineProperty(Object.prototype, "setme", { set: function (v) { seen.push(v); }, configurable: true });
var o = {};
for (var i = 0; i < 3; i++) o[key("set", "me")] = i;
assertEq(seen.join(","), "0,1,2", "inherited setter");
assertEq(Object.prototype.hasOwnProperty.call(o, "setme"), false, "no own property");
delete Object.prototype.setme;

// An inherited read-only property blocks the store (silently in sloppy code).
Object.defineProperty(Object.prototype, "frozenkey", { value: 1, writable: false, configurable: true });
var r = {};
r[key("frozen", "key")] = 2;
assertEq(r.frozenkey, 1, "read-only inherited");
assertEq(Object.prototype.hasOwnProperty.call(r, "frozenkey"), false, "not created");
delete Object.prototype.frozenkey;

// __proto__ is an accessor on Object.prototype.
var p = {};
var target = { marker: 7 };
p[key("__pro", "to__")] = target;
assertEq(Object.getPrototypeOf(p), target, "__proto__ setter");
assertEq(p.marker, 7, "inherited through the new prototype");

// A prototype chain longer than Object.prototype takes the full path.
var base = { inherited: 1 };
var child = Object.create(base);
child[key("own", 1)] = 2;
assertEq(child.own1, 2, "child own");
assertEq(Object.getPrototypeOf(child), base, "chain kept");

// Null-prototype and non-extensible receivers.
var np = Object.create(null);
np[key("n", 1)] = 1;
assertEq(np.n1, 1, "null prototype");
var ne = Object.preventExtensions({});
ne[key("x", 1)] = 1;
assertEq(ne.x1, undefined, "non-extensible sloppy");
(function () {
    "use strict";
    var threw = false;
    try { ne[key("x", 2)] = 1; } catch (e) { threw = e instanceof TypeError; }
    assertEq(threw, true, "non-extensible strict throws");
})();

// Symbols and values that need a reference count.
var s = Symbol("s");
var sym = {};
sym[s] = "v";
assertEq(sym[s], "v", "symbol key");
var vals = {};
for (var i = 0; i < 50; i++) vals[key("v", i)] = { n: key("str", i) };
assertEq(vals.v49.n, "str49", "object value");

// Reads under a computed key.
var rd = { a: 1, u: undefined, 7: "seven" };
function names() { return ["a", "u", "zz", "toString", "__proto__", "7", "hasOwnProperty"]; }
var got = [];
for (var rep = 0; rep < 3; rep++) {
    got = [];
    var ns = names();
    for (var i = 0; i < ns.length; i++) got.push(typeof rd[ns[i]]);
}
assertEq(got.join(","), "number,undefined,undefined,function,object,string,function", "computed reads");
assertEq(rd[key("", 7)], "seven", "fresh concat key finds an array-index property");

// Own and inherited accessors run their getters.
var calls = 0;
var acc = { get g() { calls++; return 5; } };
for (var i = 0; i < 3; i++) assertEq(acc[key("", "g")], 5, "own getter");
assertEq(calls, 3, "getter calls");
Object.defineProperty(Object.prototype, "viaProto", { get: function () { return "p"; }, configurable: true });
assertEq({}[key("via", "Proto")], "p", "inherited getter");
assertEq(Object.create(null)[key("via", "Proto")], undefined, "null prototype skips it");
delete Object.prototype.viaProto;

// A longer chain finds inherited data.
var chain = Object.create({ deep: 9 });
for (var i = 0; i < 3; i++) assertEq(chain[key("de", "ep")], 9, "chain read");

// Primitive and exotic receivers are unchanged.
assertEq("abc"[key("", 1)], "b", "string index");
assertEq([5, 6][key("", 1)], 6, "array index by string");
assertEq(new String("xy")[key("", 0)], "x", "string object index");

// Compound assignment to a constant-key member reads and writes through the
// same property, including when the right-hand side changes it.
(function () {
    var o = { x: 1 };
    o.x += (o.x = 10, 5);
    if (o.x !== 6) throw new Error("compound with mutating rhs: " + o.x);
    var p = { get v() { return 2; }, set v(n) { this.w = n; } };
    p.v *= 4;
    if (p.w !== 8) throw new Error("compound through accessor: " + p.w);
})();
