// A function expression that is the callee of a call is compiled in place by
// `gen`, never kept as a template, so the parser has to notice it before it
// discards the body. Deferring one would parse its whole subtree a second time on
// the call that runs it immediately. Eval compiles bodies as deferred templates,
// so every case here goes through `eval`: the callee shape, the functions its body
// still defers, and the fact that keeping the nodes changes no result.

var failures = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function run(name, source, expected) {
    var actual;
    try {
        actual = String(eval(source));
    } catch (e) {
        actual = "threw " + e.name;
    }
    check(name, actual, expected);
}

// ---- the callee shapes ----

run("parenthesised callee", "(function () { return 1; })()", "1");
run("callee inside its own parenthesis", "(function () { return 2; }())", "2");
run("callee after a unary operator", "!function () { return 3; }()", "false");
run("callee inside two parentheses", "((function () { return 4; }))()", "4");
run("callee with arguments", "(function (a, b) { return a + b; })(20, 22)", "42");
run("callee seen through arguments.length", "(function () { return arguments.length; })(1, 2, 3)", "3");
run("callee is not the callee", "(function () { return (function () { return 5; })(); })()", "5");
run("named callee", "(function named() { return 6; })()", "6");

// ---- a value that is called later stays deferred ----

run("function value called by name", "var f = function () { return 7; }; f();", "7");
run("function value passed as a callback",
    "[1, 2, 3].map(function (n) { return n * 2; }).join(',')", "2,4,6");

// ---- callee bodies still defer what they contain ----

run("declaration inside a callee",
    "(function () { var x = 1; function inner() { return x + 1; } return inner(); })()", "2");
run("method inside a callee",
    "(function () { var o = { v: 7, m: function () { return this.v; } }; return o.m(); })()", "7");
run("callee inside a loop body",
    "(function () { var s = 0; for (var i = 0; i < 3; i++) { (function () { s++; })(); } return s; })()", "3");
run("callee inside a block",
    "(function () { if (true) { return (function () { return 'yes'; })(); } return 'no'; })()", "yes");

// ---- a thrown error crosses the boundary unchanged ----

run("throw through a callee",
    "(function () { try { (function () { throw new TypeError('x'); })(); } catch (e) { return e.name; } })()",
    "TypeError");

// ---- strictness and eval inside a callee ----

run("strict callee body",
    "(function () { 'use strict'; return (function () { return 11; })(); })()", "11");
run("eval inside a callee",
    "(function () { return eval('40 + 2'); })()", "42");
run("declaration inside a callee does not leak",
    "(function () { (function () { function hidden() {} })(); return typeof hidden; })()", "undefined");

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred body callee: OK");
