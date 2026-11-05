// CALL_GLOBAL through the native call entry: the global rebound to another
// function, a non-function, a getter, a trivial callee and a throwing one.
function a(x) { var y = x + 1; if (y > 5) y = y - 1; return y; }
function b(x) { var y = x * 2; if (y > 5) y = y + 1; return y; }
function thrower(x) { var y = x; if (y > 1) throw new Error("t" + y); return y; }
function triv(x) { return x; }
var g = a;
function run(n) {
  var out = [], s = 0;
  for (var i = 0; i < n; i++) {
    if (i === 3000) g = b;
    if (i === 6000) g = 5;
    if (i === 7000) g = a;
    if (i === 8000) g = triv;
    if (i === 9000) g = thrower;
    try { s += g(i % 4); } catch (e) { s += 1000; out.push(e.message); }
  }
  return s + ":" + out.length + ":" + (out[0] || "");
}
var r = [];
try { r.push(run(12000)); } catch (e) { r.push(e.constructor.name); }
Object.defineProperty(globalThis, "h", { get() { return a; }, configurable: true });
function viaGetter(n) { var s = 0; for (var i = 0; i < n; i++) s += h(i); return s; }
r.push(viaGetter(5000));
function tdz(n) { var s = 0; for (var i = 0; i < n; i++) { try { s += late(i); } catch (e) { s += 1; } } return s; }
r.push(tdz(3000));
let late = a;
r.push(tdz(3000));
print(r.join("|") === "2522000:2500:number is not a function|12497505|3000|4498505" ? "call_global ok" : "call_global FAIL " + r.join("|"));
