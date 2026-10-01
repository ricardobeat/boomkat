// A site that reads a method off a primitive keeps following String.prototype.
function call(s) { return s.indexOf("b"); }
for (var i = 0; i < 20; i++) if (call("abc") !== 1) throw new Error("warm");

var orig = String.prototype.indexOf;
String.prototype.indexOf = function () { return -7; };
if (call("abc") !== -7) throw new Error("replaced method");
String.prototype.indexOf = orig;
if (call("abc") !== 1) throw new Error("restored method");

delete String.prototype.indexOf;
try { call("abc"); throw new Error("deleted method"); } catch (e) { if (!(e instanceof TypeError)) throw e; }
String.prototype.indexOf = orig;

// A getter added after the site was cached takes over.
function read(s) { return s.probe; }
for (var j = 0; j < 20; j++) read("x");
Object.defineProperty(String.prototype, "probe", { get: function () { return typeof this; }, configurable: true });
if (read("x") !== "string" && read("x") !== "object") throw new Error("getter");
delete String.prototype.probe;
if (read("x") !== undefined) throw new Error("getter removed");

// One site, string primitives and objects of the same shape as String.prototype.
function len(v) { return v.length; }
for (var k = 0; k < 20; k++) if (len("abcd") !== 4) throw new Error("length");
if (len(String.prototype) !== 0 || len(new String("xy")) !== 2 || len([1, 2, 3]) !== 3) throw new Error("length mix");
function idx(v) { return v[0]; }
for (var m = 0; m < 20; m++) if (idx("q") !== "q") throw new Error("index");
if (idx(String.prototype) !== undefined) throw new Error("index on prototype");

// Symbols and numbers have their own prototypes.
function desc(v) { return v.toString(); }
for (var n = 0; n < 20; n++) if (desc(Symbol("a")) !== "Symbol(a)" || desc(255) !== "255" || desc("s") !== "s" || desc(true) !== "true") throw new Error("mixed receivers");
Number.prototype.twice = function () { return this * 2; };
function twice(v) { return v.twice(); }
for (var p = 0; p < 20; p++) if (twice(21) !== 42) throw new Error("number method");
console.log("ok");
