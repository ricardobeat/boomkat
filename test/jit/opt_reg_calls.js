// Calls between optimized functions in register mode (OptCg.emit_call_reg): nested register calls,
// and exits from inside them after stores, which publish the frames of the whole chain.
function Cell(v) { this.v = v; this.n = 0; }
// Stores, then exits when c.v stops being an int32.
function inner(c, d) { c.n = c.n + 1; d = d + 1; return (c.v * 2 + d) | 0; }
function middle(c, x) { var y = inner(c, x); c.n = c.n + y; return y + 1; }
function outer(c, x) { var t = middle(c, x); return (t + middle(c, t & 3)) | 0; }
function run(n, flip) {
    var c = new Cell(3), s = 0;
    for (var i = 0; i < n; i++) {
        if (i === flip) c.v = 2.5;
        if (i === flip + 7) c.v = 4;
        s = (s + outer(c, i)) | 0;
    }
    return [s, c.n, c.v];
}
var r;
for (var k = 0; k < 300; k++) r = run(400, -100);
print(JSON.stringify(r));
print(JSON.stringify(run(400, 200)));
print(JSON.stringify(run(400, 5)));
for (var k = 0; k < 50; k++) r = run(400, k * 7);
print(JSON.stringify(r));
