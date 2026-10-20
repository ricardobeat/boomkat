// A function body whose constant pool and array literals exceed the 16-bit
// operand range: constant indexes above 0xFFFF ride on a WIDE prefix, and
// array literal indexes above the LDINT immediate load from the pool.
function check(actual, expected, what) {
    if (actual !== expected) throw new Error(what + ": expected " + expected + ", got " + actual);
}

var N = 70000;

var names = [];
for (var i = 0; i < N; i++) names.push('"s' + i + '"');
var strings = (0, eval)("[" + names.join(",") + "]");
check(strings.length, N, "string literal count");
check(strings[N - 1], "s" + (N - 1), "last string literal");

var props = [];
for (var i = 0; i < N; i++) props.push("p" + i + ": " + i);
var obj = (0, eval)("({" + props.join(",") + "})");
check(obj["p" + (N - 1)], N - 1, "last property");
check(Object.keys(obj).length, N, "property count");

var holes = [];
for (var i = 0; i < N; i++) holes.push(i % 2 ? "1" : "");
var sparse = (0, eval)("[" + holes.join(",") + ",7]");
check(sparse.length, N + 1, "array literal length");
check(sparse[N], 7, "element past the LDINT range");
check(N - 1 in sparse, true, "odd element present");
check(N - 2 in sparse, false, "hole preserved");

var reads = [];
for (var i = 0; i < N; i++) reads.push("g" + i);
globalThis.g69999 = "far";
var fn = new Function("typeof " + reads.join("; typeof ") + "; return g69999;");
check(fn(), "far", "global read by a wide name index");
var del = new Function("typeof " + reads.join("; typeof ") + "; return delete g69999;");
check(del(), true, "delete through a wide name index");
check("g69999" in globalThis, false, "deleted global");

console.log("ok");
