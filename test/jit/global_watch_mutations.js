// A configurable global shadowed later, and mutation kinds, after the reader is hot.
var out = [];
globalThis.g = function () { return 1; };
function call() { return g(); }
function inst(x) { return x instanceof K; }
function K() {}
function mk() { return new K(); }
var k = new K();
for (var i = 0; i < 5000; i++) { call(); inst(k); mk(); }
out.push(call(), inst(k), mk() instanceof K);
(0, eval)("let g = function () { return 2; };");
out.push(call());
var P = { tag: 1 };
K.prototype = P;
out.push(inst(k), Object.getPrototypeOf(mk()) === P, inst(mk()));
Object.defineProperty(K, Symbol.hasInstance, { value: function () { return "yes"; } });
out.push(inst(1));
K = function () { this.z = 3; };
out.push(mk().z, inst(k));
Object.defineProperty(globalThis, "h", { configurable: true, writable: true, value: function () { return 5; } });
function callh() { return h(); }
for (var i = 0; i < 5000; i++) callh();
Object.defineProperty(globalThis, "h", { get: function () { return function () { return 6; }; } });
out.push(callh());
delete globalThis.h;
try { callh(); out.push("no throw"); } catch (e) { out.push(e.constructor.name); }
var want = "[1,true,true,1,false,true,true,true,3,false,6,\"ReferenceError\"]";
console.log(JSON.stringify(out) === want ? "global watch mutations: ok" : "FAIL global watch mutations: " + JSON.stringify(out));
