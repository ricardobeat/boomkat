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
