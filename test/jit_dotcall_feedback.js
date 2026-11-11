// A site of Function.prototype.call keeps the feedback of the function it runs.
function inc(x) { return x + 1; }
function twice(x) { return this.k * x; }
function loop(n) { var t = 0, o = { k: 2 }; for (var i = 0; i < n; i++) t += inc.call(null, i) + twice.call(o, i); return t; }
console.log(loop(300000));
function poly(f, n) { var t = 0; for (var i = 0; i < n; i++) t += f.call({ k: 3 }, i); return t; }
console.log(poly(inc, 20000), poly(twice, 20000), poly(Math.abs, 20000));
var bad = 0;
for (var i = 0; i < 3000; i++) { try { Function.prototype.call.call(i == 2999 ? 5 : inc, null, 1); } catch (e) { bad += e instanceof TypeError; } }
console.log(bad);
