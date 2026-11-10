// Loops compiled on their own (regions): a function whose graph the optimizing tier refuses, here
// one built too large by `new Function`, still optimizes the loop a frame spends its time in, and
// leaves for the baseline code at every branch out of it. Under --opt-region-always every function
// with a loop compiles that way. The loops carry ints and doubles across iterations, start with
// registers that hold no number, break out to different places, nest, and leave values that the
// code after them reads.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

// Straight-line code that pushes the function past the whole-function graph's size.
var pad = [];
for (var p = 0; p < 1400; p++) pad.push("w = (w + " + p + ") | 0;");
var big = new Function("a", "n",
    "var w = 0;" + pad.join("") +
    "var s = 0, d = 0.5, u, last = -1;" +
    "for (var i = 0; i < n; i++) {" +
    "  u = (a[i & 7] * 3 + i) | 0;" +
    "  s = (s + u) | 0;" +
    "  d = d * 1.0001 + u / 7;" +
    "  if (u === 1000003) break;" +
    "  last = i;" +
    "}" +
    "return [w, s, Math.round(d * 1000), u, last, i].join(',');");
var arr = [1, 2, 3, 4, 5, 6, 7, 8];
var r1 = "";
for (var k = 0; k < 60; k++) r1 = big(arr, 3000);
show("big", r1);

// Nested loops with exits to the outer loop, to after both, and out of the function.
function nest(m, n, stop) {
    var total = 0, rows = 0, x;
    outer: for (var i = 0; i < m; i++) {
        var acc = i * 0.25;
        for (var j = 0; j < n; j++) {
            x = (i * 31 + j * 17) & 1023;
            if (x === stop) break outer;
            if (x < 3) continue outer;
            if (j > 900) return "early " + i + " " + j;
            acc += x;
        }
        total += acc;
        rows++;
    }
    return total + ":" + rows + ":" + x;
}
var r2 = "";
for (var k = 0; k < 40; k++) r2 = nest(60, 200, 2000) + "|" + nest(40, 200, 77);
show("nest", r2);

// A loop that turns a register from undefined to a number and back, and one whose counter
// starts as a double.
function mixed(n) {
    var v, w = 0.5, objs = 0;
    for (var i = 0; i < n; i++) {
        if (i % 97 === 0) v = undefined;
        else v = (v | 0) + i;
        w = w + 1;
        if (i % 50 === 0) objs += { a: i }.a;
    }
    return [v, w, objs].join(",");
}
var r3 = "";
for (var k = 0; k < 40; k++) r3 = mixed(2000 + k);
show("mixed", r3);

console.log(out.join("\n"));
