// Globals read, called and counted from closures created on every call of their enclosing
// function, across collections that free the scopes of earlier closures: the global's variable
// cache entry must survive them. The global is rebound, made an accessor and deleted mid-run.
function Pair(car, cdr) { this.car = car; this.cdr = cdr; }
function one(x) { return new Pair(x, null); }
var counter = 0;
var cell = 3;
function outer(n, prev) {
  var acc = null;
  for (var i = 0; i < n; i++) {
    var walk = function(l, out) {
      if (l instanceof Pair) {
        counter++;
        return walk(l.cdr, new Pair(one(l.car + cell).car, out));
      }
      return out;
    };
    acc = walk(prev, acc);
  }
  return acc;
}
var list = null;
for (var j = 0; j < 6; j++) list = new Pair(j, list);
var sum = 0;
for (var r = 0; r < 30000; r++) {
  if (r === 20000) cell = 4;
  if (r === 24000) one = function(x) { return new Pair(x * 2, null); };
  var a = outer(2, list);
  sum += a.car;
  if (r % 1000 === 0) { var junk = []; for (var k = 0; k < 2000; k++) junk.push({ k: k }); }
}
Object.defineProperty(globalThis, "late", { get() { return 7; }, configurable: true });
function readLate() { var f = function() { return late; }; return f(); }
var s2 = 0;
for (var q = 0; q < 5000; q++) {
  if (q === 3000) delete globalThis.late;
  try { s2 += readLate(); } catch (e) { s2 += 1; }
}
print(sum, counter, s2);
