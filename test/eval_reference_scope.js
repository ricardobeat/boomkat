// Only a call of `eval` by that name is a direct eval. Reading the function elsewhere in a scope
// (zlib keeps `var zlibEval = eval`) must not make that scope, and every function in it, resolve
// names dynamically; the calls below must still see the scopes the spec gives them.
var g = 1;
var e = eval;
function f() { var g = 2; return eval("g"); }      // direct: local g
function h() { var g = 3; return e("g"); }         // indirect: global g
function k() { var g = 4; return (0, eval)("g"); } // indirect
function m() { var g = 5; return eval?.("g"); }    // optional call: indirect
function p() { var g = 6; return (eval)("g"); }    // parenthesized: direct
function q(a = eval("g")) { var g = 7; return a; } // direct, in the parameter scope
function r() { eval("var z = 9"); return z; }
function s() { eval("var g2 = 10"); return function () { return g2; }; }
var got = [f(), h(), k(), m(), p(), q(), r(), s()()].join(" ");
print(got === "2 1 1 1 6 1 9 10" ? "ok" : "FAIL " + got);
