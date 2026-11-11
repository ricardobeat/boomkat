// Native calls between generated frames with fewer or more arguments than the callee declares:
// missing formals read undefined, surplus arguments are ignored and never leak into locals, and a
// rest parameter or `arguments` still sees the count. Hot enough for the call entry.
var out = [];
function two(a, b) { var l1, l2 = 7; return [a, b, l1, l2, typeof b].join(); }
function nine(a, b, c, d, e, f, g, h, i) { var z; return [a, e, i, z].join(); }
function zero() { var x; return x === undefined ? "u" : "leak:" + x; }
function rest(a, ...r) { return a + ":" + r.length; }
function args(a) { return a + ":" + arguments.length; }
function Ctor(a, b) { this.a = a; this.b = b; }
var o = { m: function (a, b, c) { var t; return [this === o, a, b, c, t].join(); } };

function run(n) {
    var s = [];
    for (var i = 0; i < n; i++) {
        s = [two(), two(1), two(1, 2), two(1, 2, 3, 4), nine(1), nine(1, 2, 3, 4, 5), nine(1, 2, 3, 4, 5, 6, 7, 8, 9, 10),
             zero(1, 2, 3), rest(1), rest(1, 2, 3), args(), args(1, 2, 3), o.m(1), o.m(1, 2, 3, 4, 5),
             JSON.stringify(new Ctor(1)), JSON.stringify(new Ctor(1, 2, 3))];
    }
    return s.join(" | ");
}
for (var k = 0; k < 20; k++) out.push(run(100));

// The same callee alternately under and over its arity from one site.
function pair(x, y) { var w; return (y === undefined ? "-" : y) + (w === undefined ? "" : "!"); }
var acc = "";
for (var i = 0; i < 3000; i++) {
    var r = (i % 3 === 0) ? pair(i) : (i % 3 === 1) ? pair(i, i + 1, i + 2) : pair(i, i);
    if (i % 997 === 0) acc += r + ";";
}
out.push(acc);
console.log(out.join("\n"));
