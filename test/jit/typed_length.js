// `length` of typed arrays at a hot site: every element type, resizable and
// length-tracking buffers, detached buffers, and `length` redefined on the
// instance or on a prototype after the site is hot.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function len(o) { return o.length; }
var ctors = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array,
  Float32Array, Float64Array, BigInt64Array, BigUint64Array];
var arrs = ctors.map(function (C, i) { return new C(i + 3); });
for (var r = 0; r < 3000; r++) {
  var i = r % arrs.length;
  if (len(arrs[i]) !== i + 3) { check("len " + r, false); break; }
}
var sub = new Uint8Array(new ArrayBuffer(32), 8, 5);
check("view", len(sub) === 5);
var rab = new ArrayBuffer(8, { maxByteLength: 64 });
var tracking = new Uint16Array(rab), fixed = new Uint16Array(rab, 0, 2);
for (var r = 0; r < 3000; r++) len(tracking);
check("tracking0", len(tracking) === 4);
rab.resize(32);
check("tracking1", len(tracking) === 16 && len(fixed) === 2);
rab.resize(2);
check("out of bounds", len(tracking) === 1 && len(fixed) === 0);
var ab = new ArrayBuffer(16), d = new Int32Array(ab);
for (var r = 0; r < 3000; r++) len(d);
check("live", len(d) === 4);
ab.transfer();
check("detached", len(d) === 0);
// An own `length` shadows the getter.
var own = new Uint8Array(4);
Object.defineProperty(own, "length", { value: 99 });
check("own", len(own) === 99);
// A subclass or prototype redefinition.
class Sub extends Uint8Array { get length() { return -1; } }
check("subclass", len(new Sub(3)) === -1);
var proto = Object.getPrototypeOf(Uint8Array.prototype);
var saved = Object.getOwnPropertyDescriptor(proto, "length");
Object.defineProperty(proto, "length", { get: function () { return 7; }, configurable: true });
check("redefined proto", len(new Uint8Array(2)) === 7);
Object.defineProperty(proto, "length", saved);
check("restored", len(new Uint8Array(2)) === 2);
Object.defineProperty(Uint8Array.prototype, "length", { value: 5, configurable: true });
check("ctor proto", len(new Uint8Array(2)) === 5 && len(new Int8Array(2)) === 2);
delete Uint8Array.prototype.length;
check("deleted", len(new Uint8Array(2)) === 2);
// Other receivers at the same site.
check("array", len([1, 2, 3]) === 3);
check("string", len("abcd") === 4);
check("object", len({ length: 12 }) === 12);
var pt = false;
try { len(new Proxy(new Uint8Array(3), {})); } catch (e) { pt = e instanceof TypeError; }
check("proxy", pt);
check("arguments", (function () { return len(arguments); })(1, 2) === 2);
// The getter called on a non-typed-array receiver throws.
var g = saved.get, threw = false;
try { g.call({}); } catch (e) { threw = e instanceof TypeError; }
check("incompatible", threw);
print(bad.length === 0 ? "typed_length ok" : "typed_length FAIL " + bad.join(","));
if (bad.length) throw new Error("typed_length failed: " + bad.join(", "));
