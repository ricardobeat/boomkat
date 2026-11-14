// `x instanceof F` with F a global function the optimized code holds as a constant, its prototype
// walked inline: a new `prototype`, an own Symbol.hasInstance, a new [[Prototype]] for F, proxies
// and bound functions on either side take effect at the next test, also from a callee while the
// code is on the stack.
function P(a) { this.a = a; }
function Q(a) { this.a = a; }
var log = [];
function check(name, got, want) { if (got !== want) log.push(name + ": " + got + " != " + want); }

var vals = [new P(1), new Q(2), 5, null, "s", {}, Object.create(new P(0)), function () {}];
// A counting loop and constructor of its own for each case: a watch that fired leaves its binding
// unfolded for good.
function C_plain(a) { this.a = a; }
function count_plain(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); if (vals[i % 8] instanceof C_plain) s++; } return s; }
function C_proto(a) { this.a = a; }
function count_proto(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); if (vals[i % 8] instanceof C_proto) s++; } return s; }
function C_has(a) { this.a = a; }
function count_has(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); if (vals[i % 8] instanceof C_has) s++; } return s; }
function C_setproto(a) { this.a = a; }
function count_setproto(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); if (vals[i % 8] instanceof C_setproto) s++; } return s; }
function C_fnproto(a) { this.a = a; }
function count_fnproto(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); if (vals[i % 8] instanceof C_fnproto) s++; } return s; }
function C_chain(a) { this.a = a; }
function count_chain(n, at, act) { var s = 0; for (var i = 0; i < n; i++) { if (i === at) act(); if (vals[i % 8] instanceof C_chain) s++; } return s; }
function setup(name) {
  var C = globalThis["C_" + name];
  vals[0] = new C(1);
  vals[6] = Object.create(new C(0));
  var count = globalThis["count_" + name];
  for (var k = 0; k < 40; k++) count(400, -1, null);
  return C;
}
function run(name, at, act) { return globalThis["count_" + name](8000, at, act); }

var C = setup("plain");
check("plain", run("plain", -1, null), 2000);
// A new prototype object: only objects made from it now pass.
C = setup("proto");
check("prototype", run("proto", 4000, function () { C.prototype = Q.prototype; }), 1000 + 500);
// An own Symbol.hasInstance, and its deletion.
C = setup("has");
check("hasInstance", run("has", 4000, function () {
  Object.defineProperty(C, Symbol.hasInstance, { value: function (v) { return v === 5; }, configurable: true });
}), 1000 + 500);
delete C[Symbol.hasInstance];
check("hasInstance deleted", run("has", -1, null), 2000);
// F's own [[Prototype]] given a Symbol.hasInstance.
var withHas = Object.create(Function.prototype);
Object.defineProperty(withHas, Symbol.hasInstance, { value: function (v) { return typeof v === "string"; } });
C = setup("setproto");
check("setPrototypeOf", run("setproto", 4000, function () { Object.setPrototypeOf(C, withHas); }), 1000 + 500);
// Function.prototype's Symbol.hasInstance is neither writable nor configurable.
C = setup("fnproto");
var r;
try { Object.defineProperty(Function.prototype, Symbol.hasInstance, { value: function () { return true; } }); r = "defined"; } catch (e) { r = e.constructor.name; }
check("Function.prototype hasInstance", r, "TypeError");
check("after", run("fnproto", -1, null), 2000);
// The prototype's own [[Prototype]] changed: objects made from it still pass, the others do not.
C = setup("chain");
check("chain", run("chain", 4000, function () { Object.setPrototypeOf(vals[1], C.prototype); }), 1000 + 1500);

// Proxies and bound functions on either side.
var pp = new Proxy(new P(3), {});
var pf = new Proxy(P, {});
var bf = P.bind(null);
function sides(n) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    if (pp instanceof P) s += 1;
    if (new P(i) instanceof pf) s += 10;
    if (new P(i) instanceof bf) s += 100;
    if (vals[i % 8] instanceof P) s += 1000;
  }
  return s;
}
check("sides", sides(4000), 4000 * 111);

// A rebinding of the global itself.
function R() {}
var rv = [new R(), new P(0)];
function viaGlobal(n, at) {
  var s = 0;
  for (var i = 0; i < n; i++) {
    if (i === at) R = P;
    if (rv[i & 1] instanceof R) s++;
  }
  return s;
}
for (var k = 0; k < 40; k++) viaGlobal(400, -1);
check("rebound", viaGlobal(4000, 2000), 1000 + 1000);

print(log.length === 0 ? "instanceof_watch ok" : "instanceof_watch FAIL\n" + log.join("\n"));
