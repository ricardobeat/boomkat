// Branches whose distance exceeds the 16-bit offset field: conditional
// branches and TRY catch offsets get a WIDE prefix carrying the high bits.
function check(actual, expected, what) {
    if (actual !== expected) throw new Error(what + ": expected " + expected + ", got " + actual);
}

var BODY = 70000;
var body = new Array(BODY + 1).join("x += 1;");
var expr = new Array(BODY + 1).join("x += 1, ") + "x";

var cond = new Function("c", "var x = 0; if (c) {" + body + "} else { x = -1; } return x;");
check(cond(true), BODY, "if taken");
check(cond(false), -1, "else past a far branch");

var loop = new Function("n", "var x = 0; for (var i = 0; i < n; i++) {" + body + "} return x;");
check(loop(3), 3 * BODY, "for loop back-edge");
check(loop(0), 0, "for loop skipped");

var whileLoop = new Function("n", "var x = 0; while (n-- > 0) {" + body + "} return x;");
check(whileLoop(2), 2 * BODY, "while loop");

var doWhile = new Function("n", "var x = 0; do {" + body + "} while (--n > 0); return x;");
check(doWhile(3), 3 * BODY, "do-while back-edge");

var tryCatch = new Function("t",
    "var x = 0, log = ''; try {" + body + " if (t) throw 7; log += 'b'; }" +
    " catch (e) { log += 'c' + e; } finally { log += 'f'; } return log + x;");
check(tryCatch(true), "c7f" + BODY, "catch past a far TRY");
check(tryCatch(false), "bf" + BODY, "finally past a far TRY");

var logical = new Function("c", "var x = 0; return (c && (" + expr + ")) || -1;");
check(logical(true), BODY, "&& evaluated");
check(logical(false), -1, "&& short-circuit");

var ternary = new Function("c", "var x = 0; return c ? (" + expr + ") : -2;");
check(ternary(true), BODY, "?: consequent");
check(ternary(false), -2, "?: alternate");

var gen = new Function("return function* (c) { var x = 0; if (c) {" + body + " yield x;" + body + "} yield x; };")();
var it = gen(true);
check(it.next().value, BODY, "generator yield inside a far branch");
check(it.next().value, 2 * BODY, "generator resumed inside a far branch");
check(gen(false).next().value, 0, "generator skipping a far branch");

console.log("ok");
