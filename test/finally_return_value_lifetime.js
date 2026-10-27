// A value returned through a finally block stays alive while the finally runs,
// even when the register it came from is reused or overwritten.
function check(name, got, want) {
    if (got !== want) throw new Error(name + ": got " + String(got) + ", want " + String(want));
}
function mk(n) { return "ab".repeat(n); }
var sink = [];
function churn() { for (var i = 0; i < 8; i++) sink.push(mk(i + 3) + i); sink.length = 0; }

check("concat", (function () {
    var l = [];
    try { return mk(3) + 1; } finally { l.push("f"); l.push("g"); churn(); }
})(), "ababab1");

check("catch return", (function () {
    var l = [];
    try { try { throw 1; } catch (e) { return mk(3) + e; } finally { l.push("f"); churn(); } } finally { l.push("g"); churn(); }
})(), "ababab1");

check("overwritten local", (function () {
    var s = mk(4) + "x";
    try { return s; } finally { s = 2; churn(); }
})(), "abababab" + "x");

check("object", (function () {
    var o = { a: [1, 2, 3] };
    try { return o; } finally { o = null; churn(); }
})().a.length, 3);

check("nested finally", (function () {
    try { try { return mk(2) + 1; } finally { churn(); } } finally { churn(); }
})(), "abab1");

check("return in finally replaces", (function () {
    try { return mk(2) + 1; } finally { return mk(3) + 2; }
})(), "ababab2");

check("throw in finally drops return", (function () {
    try { try { return mk(2) + 1; } finally { throw new Error("x"); } } catch (e) { return mk(1) + "c"; }
})(), "abc");

check("break in finally drops return", (function () {
    for (var i = 0; i < 1; i++) {
        try { return mk(2) + 1; } finally { churn(); break; }
    }
    return "after";
})(), "after");

function* gen() { try { yield 1; return mk(3) + 4; } finally { churn(); } }
var g = gen(); g.next();
var r = g.next();
check("generator", r.value, "ababab4");
check("generator done", r.done, true);

var g2 = gen(); g2.next();
check("generator return()", g2.return(mk(2) + 5).value, "abab5");

(async function () {
    try { return mk(3) + 6; } finally { churn(); }
})().then(function (v) { check("async", v, "ababab6"); print("ok"); });
