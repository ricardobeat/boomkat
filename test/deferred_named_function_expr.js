// A named function expression whose body is deferred still binds its own name:
// read-only, visible only inside, and shadowed by a parameter or a var.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var fact = function f(n) { return n < 2 ? 1 : n * f(n - 1); };
check("recursion through the name", fact(5), 120);

var f = "global f";
var g = function f() { return typeof f; };
check("the name shadows a global", g(), "function");
check("the name does not leak", typeof f, "string");

var w = function self() { self = 1; return typeof self; };
check("sloppy assignment is ignored", w(), "function");
var s = function self() { "use strict"; try { self = 1; return "no throw"; } catch (e) { return e.name; } };
check("strict assignment throws", s(), "TypeError");

check("a parameter shadows the name", (function h(h) { return h; })(7), 7);
var v = function k() { var k = 3; return k; };
check("a var shadows the name", v(), 3);

function outer() { var r = function rec(n) { return n ? rec(n - 1) + 1 : 0; }; return r(4); }
check("nested in a deferred body", outer(), 4);

var gen = function q() { return function () { return q; }; };
check("captured by an inner function", gen()(), gen);
check("as a constructor", new (function C() { this.c = C.name; })().c, "C");
check("name property", fact.name, "f");

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred named function expr: OK");
