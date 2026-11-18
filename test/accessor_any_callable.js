// An accessor's getter or setter can be any callable: a bound function, a
// callable proxy, a builtin. The property read and write paths staged a frame
// only for a function with bytecode or a builtin with a dispatch index; any
// other getter left the read's destination register as it was (the key, the
// descriptor), and any other setter was skipped. Both now go through the host
// call.
"use strict";

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function f(k) { return this.v + (k === undefined ? 0 : k); }
var o = { v: 42 };

// Own accessor, bound getter and setter.
var own = Object.defineProperty({}, "b", { get: f.bind(o), set: function (x) { this.got = x; }.bind(o) });
check("own bound getter", own.b, 42);
own.b = 9;
check("own bound setter", o.got, 9);

// Inherited, read and written in a hot loop.
var proto = {};
Object.defineProperty(proto, "g", { get: f.bind(o, 1), set: function (x) { this.last = x; }.bind(o) });
var child = Object.create(proto);
var sum = 0;
for (var i = 0; i < 2000; i++) { sum += child.g; child.g = i; }
check("inherited bound getter", sum, 86000);
check("inherited bound setter", o.last, 1999);
check("setter defined no own property", Object.hasOwn(child, "g"), false);

// Keyed, destructured, through super and Reflect.
var key = "g";
check("keyed read", child[key], 43);
var { g } = child;
check("destructured read", g, 43);
class A {}
Object.defineProperty(A.prototype, "w", { get: f.bind({ v: 3 }) });
class B extends A { m() { return super.w; } }
check("super read", new B().m(), 3);
check("Reflect.get", Reflect.get(child, "g"), 43);

// A bound builtin and callable proxies.
var mixed = Object.defineProperty({}, "m", {
    get: Math.max.bind(null, 1, 5),
    set: new Proxy(function (v) { o.proxied = v; }, {}),
});
check("bound builtin getter", mixed.m, 5);
mixed.m = 11;
check("proxy setter", o.proxied, 11);
var viaProxy = Object.defineProperty({}, "p", { get: new Proxy(function () { return "proxied"; }, {}) });
check("proxy getter", viaProxy.p, "proxied");

// Throws reach the reader's and writer's catch.
var thrower = Object.defineProperty({}, "t", {
    get: function () { throw new RangeError("get " + this.n); }.bind({ n: 1 }),
    set: function () { throw new TypeError("set"); }.bind(null),
});
var caught = "";
try { thrower.t; } catch (e) { caught += e.name + ":" + e.message; }
try { thrower.t = 1; } catch (e) { caught += " " + e.name + ":" + e.message; }
check("throws", caught, "RangeError:get 1 TypeError:set");

// A global accessor read by name.
Object.defineProperty(globalThis, "boundGlobal", { get: f.bind({ v: 5 }), configurable: true });
check("global bound getter", boundGlobal, 5);

if (failures === 0) print("accessor_any_callable: ok");
