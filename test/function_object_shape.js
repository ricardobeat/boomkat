// Ordinary functions get length, name and prototype in spec order, and a fresh
// prototype object with its own constructor, however they are created.
function assert(c, m) { if (!c) throw new Error(m); }
function make() { return function (a, b) {}; }
var f1 = make(), f2 = make();
assert(Object.getOwnPropertyNames(f1).join() === "length,name,prototype", "own keys");
assert(f1.length === 2 && f1.name === "", "length/name");
assert(f1.prototype !== f2.prototype, "fresh prototype per closure");
assert(f1.prototype.constructor === f1, "constructor");
assert(Object.getPrototypeOf(f1.prototype) === Object.prototype, "proto of prototype");
var d = Object.getOwnPropertyDescriptor(f1, "prototype");
assert(d.writable && !d.enumerable && !d.configurable, "prototype flags");
d = Object.getOwnPropertyDescriptor(f1, "name");
assert(!d.writable && !d.enumerable && d.configurable, "name flags");
d = Object.getOwnPropertyDescriptor(f1.prototype, "constructor");
assert(d.writable && !d.enumerable && d.configurable, "constructor flags");
f1.prototype = { x: 1 };
assert(new f1().x === 1 && new f2() instanceof f2, "construct");
delete f2.name;
assert(f2.name === "" && make().name === "", "delete name");
console.log("ok");
