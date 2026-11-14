// `instanceof` in small functions the optimizing tier inlines into their callers: lists walked
// with it, primitives and functions on the left, the constructor's `prototype` reassigned midway,
// a Symbol.hasInstance installed later, a bound constructor, a proxy on the chain and a
// non-callable right operand that throws.
function Pair(car, cdr) { this.car = car; this.cdr = cdr; }
function Other() {}
function isPair(x) { return x instanceof Pair; }
function isA(x, C) { return x instanceof C; }
function len(l) { var n = 0; while (isPair(l)) { n++; l = l.cdr; } return n; }
function list(n) { var l = null; for (var i = 0; i < n; i++) l = new Pair(i, l); return l; }
var l = list(6), s = 0, out = [];
for (var i = 0; i < 40000; i++) {
  s += len(i % 3 ? l : l.cdr);
  s += isA(i, Pair) ? 100 : 1;
  s += isA(isA, Function) ? 1 : 0;
  s += isA(new Other(), i % 2 ? Pair : Other) ? 1 : 0;
  if (i === 20000) { out.push(len(l)); Pair.prototype = {}; out.push(len(l), len(new Pair(1, null))); }
}
out.push(s);
var viaProxy = Object.create(new Proxy(Pair.prototype, {}));
var t = 0;
for (var j = 0; j < 20000; j++) {
  if (j === 10000) Object.defineProperty(Pair, Symbol.hasInstance, { value: function(v) { return typeof v === "number"; } });
  t += isA(viaProxy, Pair) ? 1 : 0;
  t += isA(j, Pair) ? 10 : 0;
  t += isA(new Pair(0, null), Pair.bind(null)) ? 100 : 0;
}
out.push(t);
try { for (var k = 0; k < 10000; k++) isA(k, k < 9000 ? Other : {}); } catch (e) { out.push(e.constructor.name, k); }
print(out.join(" "));
