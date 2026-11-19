// Cached reads whose entry names anything but an own data property, which baseline code takes
// out of line (Asm.emit_get_cold): getters, absent properties, inherited data properties found
// through an epoch or a recorded chain, and one site meeting all of them.
var out = [];
function log(x) { out.push(String(x)); }

function Box(v) { this.v = v; }
Object.defineProperty(Box.prototype, "twice", { get: function () { return this.v * 2; }, configurable: true });
Box.prototype.shared = 5;
Box.prototype.read = function () { return this.twice + this.shared + (this.absent === undefined ? 1 : 0); };

function readTwice(b) { return b.twice; }
function readShared(b) { return b.shared; }
function readAbsent(b) { return b.absent; }

var b = new Box(3);
var s = 0;
for (var i = 0; i < 400; i++) s += readTwice(b) + readShared(b) + b.read() + (readAbsent(b) === undefined ? 1 : 0);
log(s);

// The absent property appears on the prototype, then on the object.
Box.prototype.absent = "proto";
log(readAbsent(b));
b.absent = "own";
log(readAbsent(b));

// A getter that throws, and one replaced by a data property.
Object.defineProperty(Box.prototype, "twice", { get: function () { throw new Error("boom"); }, configurable: true });
try { readTwice(b); } catch (e) { log(e.message); }
Object.defineProperty(Box.prototype, "twice", { value: 42, configurable: true });
log(readTwice(b));

// One site, four kinds of receiver: own, inherited, accessor, absent.
function readK(o) { return o.k; }
var own = { k: 1 };
var inherited = Object.create({ k: 2 });
var accessor = { get k() { return 3; } };
var none = {};
var t = 0;
for (var i = 0; i < 300; i++) t += readK(own) + readK(inherited) + readK(accessor) + (readK(none) === undefined ? 4 : 0);
log(t);

// A chain the epoch cannot describe: a prototype with a proxy above it, and a deep chain.
var proxied = Object.create(new Proxy({ k: 7 }, {}));
var deep = Object.create(Object.create(Object.create({ k: 8 })));
var u = 0;
for (var i = 0; i < 300; i++) u += readK(proxied) + readK(deep);
log(u);

// Reads through `this` in a getter-heavy class.
class Point {
    constructor(x, y) { this.x = x; this.y = y; }
    get len2() { return this.x * this.x + this.y * this.y; }
    sum() { return this.len2 + this.x; }
}
var p = new Point(3, 4);
var w = 0;
for (var i = 0; i < 300; i++) w += p.sum();
log(w);

// A string primitive's inherited method and length.
function strRead(x) { return x.length + x.charAt(0); }
var q = "";
for (var i = 0; i < 300; i++) q = strRead("abc");
log(q);

print(out.join("\n"));
