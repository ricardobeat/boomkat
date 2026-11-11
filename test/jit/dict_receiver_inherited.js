// Inherited reads through an object with enough properties to be a dictionary: once its keys
// stand still the reads are cached, and a key that arrives afterwards (shadowing a method or
// a prototype value), a deleted one, a changed prototype or a prototype edit must all be seen
// by the very next read.
var out = [];
function Big() { for (var i = 0; i < 90; i++) this["f" + i] = i; }
Big.prototype.tag = "proto";
Big.prototype.get = function () { return this.tag; };
Big.prototype.sum = function () { return this.f1 + this.f89; };
function read(o) { return o.tag; }
function call(o) { return o.get() + ":" + o.sum(); }
function self(o) { var s = ""; for (var i = 0; i < 3; i++) s += o.get(); return s; }

var b = new Big();
function spin() { var r = ""; for (var i = 0; i < 300; i++) r = read(b) + "/" + call(b) + "/" + self(b); return r; }
out.push(spin());
b.tag = "own";                               // shadows a cached prototype value
out.push(spin());
b.get = function () { return "shadow"; };    // shadows a cached method
out.push(spin());
delete b.get;
out.push(spin());
delete b.tag;
out.push(spin());
Big.prototype.tag = "edited";                // the prototype's value changes in place
out.push(spin());
Big.prototype.get = function () { return "g2:" + this.tag; };
out.push(spin());
var other = { tag: "other", get: function () { return "o:" + this.tag; }, sum: function () { return -1; } };
Object.setPrototypeOf(b, other);
out.push(spin());
Object.setPrototypeOf(b, Big.prototype);
out.push(spin());
b.extra1 = 1;                                // unrelated keys keep the reads right
out.push(spin());
for (var k = 0; k < 40; k++) { b["late" + k] = k; if (read(b) !== "edited") out.push("stale " + k); }
out.push(spin());

// A map filled while an inherited method is called on it, and keys that later shadow it.
var map = {};
var seen = 0;
for (var n = 0; n < 4000; n++) {
    map["k" + n] = n;
    if (map.hasOwnProperty("k" + (n >> 1))) seen++;
    if (n === 3000) map.hasOwnProperty = function () { return false; };
}
out.push(seen);

// Two dictionaries of one constructor never share a cached answer.
var p = new Big(), q = new Big();
q.tag = "q";
var mixed = "";
for (var m = 0; m < 200; m++) mixed = read(p) + read(q) + call(m & 1 ? p : q);
out.push(mixed);
console.log(out.join("\n"));
