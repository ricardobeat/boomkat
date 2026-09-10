// Direct eval must run in the caller's lexical environment (ES2015 §18.2.1.1):
// it can read the caller's vars, params, and let/const bindings, while its own
// var declarations stay in a fresh env (strict-only engine) and do not leak.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

function e1() { var v = 7; return eval("v"); }
ck("caller-var", e1(), 7);

function e2(q) { return eval("q * 2"); }
ck("caller-param", e2(21), 42);

function e3() { let L = 8; return eval("L"); }
ck("caller-let", e3(), 8);

function e4() { const C = 9; return eval("C"); }
ck("caller-const", e4(), 9);

function e5() { let [d] = [5]; return eval("d"); }
ck("caller-destructured-let", e5(), 5);

function e6() { if (true) { const B = 3; return eval("B"); } }
ck("caller-block-const", e6(), 3);

// eval can call caller-visible functions and combine bindings
function e7() { var a = 2; let b = 3; return eval("a * b"); }
ck("caller-mixed", e7(), 6);

// Sloppy direct eval declares vars in the caller's var env (§17.1.3);
// a strict direct eval keeps them in the eval's own env (§18.2.1.3).
function e8() {
    eval("var leaked = 1;");
    return typeof leaked;
}
ck("sloppy-eval-var-reaches-caller", e8(), "number");
function e8s() {
    "use strict";
    eval("var leaked_s = 1;");
    return typeof leaked_s;
}
ck("strict-eval-no-var-leak", e8s(), "undefined");

// indirect eval sees only globals
var G = 11;
function e9() { var hidden = 5; var ind = eval; return ind("typeof hidden + ':' + G"); }
ck("indirect-global-only", e9(), "undefined:11");

// nested: closure inside eval capturing caller binding
function e10() { let n = 4; return eval("(function(){ return n + 1; })()"); }
ck("closure-inside-eval", e10(), 5);

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error(f + " direct-eval-scope failures"); }
