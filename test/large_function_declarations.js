// More global function declarations than a 16-bit index can name: each must
// keep its own closure, and a later duplicate still wins.
function check(actual, expected, what) {
    if (actual !== expected) throw new Error(what + ": expected " + expected + ", got " + actual);
}

var N = 70000;
var decls = [];
for (var i = 0; i < N; i++) decls.push("function h" + i + "() { return " + i + "; }");

(0, eval)(decls.join("\n") + "\nfunction h5() { return -5; }");
check(h0(), 0, "first global function");
check(h69999(), N - 1, "last global function");
check(h5(), -5, "duplicate declaration wins");

// A function scope keeps each declaration in a register, so it stays under 65536.
var nested = new Function(decls.slice(0, 10000).join("\n") + "\nfunction h7() { return -7; }" +
    "\nreturn [h0(), h7(), h9999()].join();");
check(nested(), "0,-7,9999", "nested function declarations");

console.log("ok");
