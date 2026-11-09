// Object and array allocations inside an inlined callee: the optimizing tier builds the object its
// own code (OptOp.ALLOC) and fills the slots an object literal's shape names (OptOp.INIT_SLOT),
// including literals whose slots hold strings and other heap values, and objects that outlive the
// call through every exit.
var out = [];
function show(label, v) { out.push(label + "=" + String(v)); }

function pt(x, y) { return { x: x, y: y }; }
function big(a) { return { a: a, b: a + 1, c: a + 2, d: "s", e: null, f: true, g: a - 1, h: 0.5 }; }
function tagged(v) { return { v: v, t: typeof v }; }
function arr(n) { return [n, n + 1]; }
function pairSum(a, b) { var p = pt(a, b); return p.x + p.y; }
function nestedObj(a) { var o = { inner: pt(a, a + 1) }; return o.inner.x + o.inner.y; }
function arrOfObjs(n) { return [pt(n, n + 1), pt(n + 2, n + 3)]; }

var warm = function (f, a, b) { for (var i = 0; i < 4000; i++) f(a, b); };
warm(pt, 1, 2); warm(big, 1, 2); warm(tagged, 1, 2); warm(arr, 1, 2);
warm(pairSum, 1, 2); warm(nestedObj, 1, 2); warm(arrOfObjs, 1, 2);

var s = 0;
for (var i = 0; i < 8000; i++) s += pairSum(i % 13, (i % 7) + 1);
show("pairSum", s);
s = 0;
for (var i = 0; i < 8000; i++) s += nestedObj(i % 13);
show("nestedObj", s);
s = 0;
for (var i = 0; i < 8000; i++) { var p = arrOfObjs(i % 11); s += p[0].x + p[1].y; }
show("arrOfObjs", s);

var vals = [1, 1.5, "s", undefined, null, {}, [], function () {}, true, 10n, Symbol("q")];
var seen = [];
for (var i = 0; i < vals.length * 400; i++) {
    var t = tagged(vals[i % vals.length]);
    if (i % 400 === 0) seen.push(String(t.t));
}
show("tagged", seen.join(","));

var b = big(3);
show("big", [b.a, b.b, b.c, b.d, b.e, b.f, b.g, b.h].join(","));

// The literals are kept, so the graph's frames must have published them at every exit: a
// collection forced between iterations sees the objects only through the caller's registers.
var kept = [];
for (var i = 0; i < 20000; i++) {
    var p = pt(i, i + 1);
    if (i % 5000 === 0) kept.push(p);
    if (i % 1000 === 0) { var junk = big(i); junk.d = String(i); }
}
var sum = 0;
for (var i = 0; i < kept.length; i++) sum += kept[i].x + kept[i].y;
show("kept", kept.length + ":" + sum);
show("pt.fields", [pt(1, 2).x, pt(1, 2).y, pt("s", null).x, pt("s", null).y].join(","));

// A literal whose slot holds a string the caller keeps: the store is a traced one.
var names = [];
for (var i = 0; i < 2000; i++) {
    var t = tagged("v" + (i % 3));
    if (i % 100 === 0) names.push(t.v + "/" + t.t);
}
show("names", names.join(","));

print(out.join("\n"));
