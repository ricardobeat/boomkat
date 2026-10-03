// Function objects get length/name (and .prototype when they have one) in one
// step, and builtins that Get "constructor" on an array read through the
// megamorphic cache. Neither may change what scripts can observe.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}
function keys(f) { return Reflect.ownKeys(f).map(String).join(); }
function desc(f, k) {
    var d = Object.getOwnPropertyDescriptor(f, k);
    return d.writable + "/" + d.enumerable + "/" + d.configurable;
}

var arrow = (a, b) => a;
var method = ({ m(a) {} }).m;
var getter = Object.getOwnPropertyDescriptor({ get g() { return 1; } }, "g").get;
var asyncFn = async function (a, b, c) {};
var plain = function plain(a) {};
check("arrow keys", keys(arrow), "length,name");
check("method keys", keys(method), "length,name");
check("getter keys", keys(getter), "length,name");
check("async keys", keys(asyncFn), "length,name");
check("plain keys", keys(plain), "length,name,prototype");
check("arrow length", arrow.length, 2);
check("arrow name", arrow.name, "arrow");
check("anonymous arrow name", (() => {}).name, "");
check("method name", method.name, "m");
check("getter name", getter.name, "get g");
check("async length", asyncFn.length, 3);
check("length flags", desc(arrow, "length"), "false/false/true");
check("name flags", desc(arrow, "name"), "false/false/true");
check("prototype flags", desc(plain, "prototype"), "true/false/false");
check("no arrow prototype", arrow.hasOwnProperty("prototype"), false);
check("no method prototype", method.hasOwnProperty("prototype"), false);
check("default stops length", ((a, b = 1, c) => {}).length, 1);
check("rest stops length", ((a, ...r) => {}).length, 1);

// A bare function still accepts new properties and redefinition.
arrow.extra = 1;
check("extra", keys(arrow), "length,name,extra");
Object.defineProperty(arrow, "name", { value: "renamed" });
check("renamed", arrow.name, "renamed");
check("sibling unaffected", ((a, b) => a).name, "");
delete arrow.length;
check("deleted length", arrow.hasOwnProperty("length"), false);
check("sibling keeps length", ((a, b) => a).length, 2);
var fresh = (a, b) => a;
check("fresh after delete", keys(fresh), "length,name");

// Array.prototype methods consult `constructor` on the receiver.
var calls = 0;
class Sub extends Array { static get [Symbol.species]() { calls++; return Array; } }
var sub = new Sub(1, 2, 3);
check("subclass map", sub.map(x => x) instanceof Sub, false);
check("species consulted", calls, 1);
check("plain map", [1, 2].map(x => x).constructor, Array);

var a = [1, 2, 3];
for (var i = 0; i < 4; i++) a.map(x => x);
a.constructor = function C(n) { return { length: 0, tag: "own" }; };
check("own constructor without species", a.map(x => x).tag, undefined);

var b = [1, 2, 3];
for (var i = 0; i < 4; i++) b.filter(x => x);
b.constructor = undefined;
check("undefined constructor", Array.isArray(b.filter(x => x)), true);

var c = [1, 2, 3];
for (var i = 0; i < 4; i++) c.slice();
var saved = Array.prototype.constructor;
Array.prototype.constructor = function Fake() { return { fake: true }; };
check("replaced prototype constructor", c.slice().fake, undefined);
Array.prototype.constructor = saved;
check("restored", Array.isArray(c.slice()), true);

var d = [1, 2];
for (var i = 0; i < 4; i++) d.map(x => x);
Object.setPrototypeOf(d, { constructor: undefined, map: Array.prototype.map });
check("swapped proto", Array.isArray(d.map(x => x)), true);

// Index keys and length on arrays are read from the array, not a cached slot.
var e = [10, 20];
for (var i = 0; i < 4; i++) e.length;
Array.prototype[5] = "p";
check("inherited index", [1, 2, 3, 4, 5, 6][5], 6);
check("hole reads proto", [1][5], "p");
delete Array.prototype[5];
check("length", [1, 2, 3].length, 3);

// Getter on the prototype is still called with the array as receiver.
var seen;
Object.defineProperty(Array.prototype, "probe", { configurable: true, get() { seen = this; return 7; } });
var f = [1];
for (var i = 0; i < 4; i++) check("getter", f.probe, 7);
check("receiver", seen, f);
delete Array.prototype.probe;
check("getter gone", f.probe, undefined);
print("ok");
