// `g++` and `g--` on a global, inline while it holds a fastint that stays one: every other value
// (a double, a string, the edge of the int32 range, an accessor, a const, a deleted or redefined
// global) takes the general path with the same result.
var out = [];
var n = 0, d = 0, f = 0.5, s = "7", big = 2147483646, small = -2147483647, u;
function up(k) { for (var i = 0; i < k; i++) n++; return n; }
function down(k) { for (var i = 0; i < k; i++) d--; return d; }
function post() { var a = n++; var b = d--; return a + "," + b + "," + n + "," + d; }
function pre() { return (++n) + "," + (--d); }
function others() { f++; s++; u++; big++; small--; return [f, s, u, big, small].join(); }
for (var r = 0; r < 30; r++) { up(100); down(100); }
out.push(n, d, post(), pre());
for (var r = 0; r < 5; r++) out.push(others());
var hits = 0;
Object.defineProperty(globalThis, "acc", { get: function () { return hits; }, set: function (v) { hits = v * 2; }, configurable: true });
function accessor() { for (var i = 0; i < 300; i++) acc++; return hits; }
out.push(accessor());
globalThis.loose = 5;
function loose_step() { loose++; return loose; }
for (var r = 0; r < 300; r++) loose_step();
out.push(loose);
delete globalThis.loose;
try { loose_step(); out.push("no throw"); } catch (e) { out.push(e.name); }
globalThis.loose = "x";
out.push(loose_step());
Object.defineProperty(globalThis, "frozen", { value: 1, writable: false, configurable: true });
function frozen_step() { frozen++; return frozen; }
for (var r = 0; r < 300; r++) frozen_step();
out.push(frozen);
n = 2147483600;
out.push(up(100));
d = -2147483600;
out.push(down(100));
console.log(out.join("\n"));
