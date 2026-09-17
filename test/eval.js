// eval() tests — ES5 §15.1.2.1
//
// NOTE: function definitions currently have a pre-existing compiler bug,
// so tests are written with inline code instead of helper functions.

var pass = 0;
var fail = 0;

// --- Test 1: eval with no argument ---
var r1 = eval();
if (r1 === undefined) { print("PASS: eval() returns undefined"); pass++; }
else { print("FAIL: eval() expected undefined got " + r1); fail++; }

// --- Test 2: eval with non-string argument ---
var r2a = eval(42);
if (r2a === 42) { print("PASS: eval(42) returns 42"); pass++; }
else { print("FAIL: eval(42) expected 42 got " + r2a); fail++; }

var r2b = eval(true);
if (r2b === true) { print("PASS: eval(true) returns true"); pass++; }
else { print("FAIL: eval(true) expected true got " + r2b); fail++; }

var r2c = eval(null);
if (r2c === null) { print("PASS: eval(null) returns null"); pass++; }
else { print("FAIL: eval(null) expected null got " + r2c); fail++; }

// --- Test 3: eval with simple numeric expression ---
var r3 = eval("1 + 2");
if (r3 === 3) { print("PASS: eval('1+2') === 3"); pass++; }
else { print("FAIL: eval('1+2') expected 3 got " + r3); fail++; }

// --- Test 4: eval with string ---
var r4 = eval('"hello"');
if (r4 === "hello") { print("PASS: eval string literal"); pass++; }
else { print("FAIL: eval string literal expected hello got " + r4); fail++; }

// --- Test 5: eval with boolean expression ---
var r5 = eval("1 < 2");
if (r5 === true) { print("PASS: eval('1<2') === true"); pass++; }
else { print("FAIL: eval('1<2') expected true"); fail++; }

// --- Test 6: eval var scoping follows the eval's strictness ----------------
// A sloppy direct eval declares vars in the caller's variable environment
// (ES2024 §17.1.3), so eval_x becomes a global binding. A strict eval
// installs declarations in a fresh declarative env (§18.2.1.3) and leaks
// nothing.
eval("var eval_x = 42");
if (eval_x === 42) { print("PASS: sloppy eval var declares in the caller's var env"); pass++; }
else { print("FAIL: sloppy eval var missing, eval_x = " + eval_x); fail++; }
(function () {
    eval('"use strict"; var eval_xs = 43;');
    if (typeof eval_xs === "undefined") { print("PASS: strict eval var does not leak"); pass++; }
    else { print("FAIL: strict eval var leaked, eval_xs = " + eval_xs); fail++; }
})();

// --- Test 7: eval returns last expression value ---
var r7 = eval("1; 2; 3");
if (r7 === 3) { print("PASS: eval returns last expression"); pass++; }
else { print("FAIL: eval last expr expected 3 got " + r7); fail++; }

// --- Test 8: eval with arithmetic ---
var r8 = eval("10 * 5");
if (r8 === 50) { print("PASS: eval('10*5') === 50"); pass++; }
else { print("FAIL: eval('10*5') expected 50 got " + r8); fail++; }

// --- Test 9: eval with nested expressions ---
var r9 = eval("(1 + 2) * 3");
if (r9 === 9) { print("PASS: eval('(1+2)*3') === 9"); pass++; }
else { print("FAIL: eval('(1+2)*3') expected 9 got " + r9); fail++; }

// --- Test 10: eval with function expression ---
var fn = eval("(function(a, b) { return a + b; })");
if (typeof fn === "function") { print("PASS: eval returns function"); pass++; }
else { print("FAIL: eval returns function expected function"); fail++; }

var r10 = fn(3, 4);
if (r10 === 7) { print("PASS: eval-created function works"); pass++; }
else { print("FAIL: eval-created fn expected 7 got " + r10); fail++; }

// --- Test 11: eval with if statement ---
var r11 = eval("if (true) { 99 } else { 0 }");
// if-statement doesn't produce a value for eval return — just check no error

// --- Test 12: eval with variable in expression ---
// Sloppy eval vars land in the caller's var env (see test 6).
eval("var eval_y = 100");
if (eval_y === 100) { print("PASS: sloppy eval var visible after eval"); pass++; }
else { print("FAIL: sloppy eval var missing, eval_y = " + eval_y); fail++; }

// --- Test 13: empty eval ---
var r13 = eval("");
if (r13 === undefined) { print("PASS: eval('') returns undefined"); pass++; }
else { print("FAIL: eval('') expected undefined"); fail++; }

// --- Test 14: eval only whitespace ---
var r14 = eval("   ");
if (r14 === undefined) { print("PASS: eval('   ') returns undefined"); pass++; }
else { print("FAIL: eval('   ') expected undefined"); fail++; }

// --- Test 15: indirect eval ---
var indirect_eval = eval;
var r15 = indirect_eval("1 + 2");
if (r15 === 3) { print("PASS: indirect eval === 3"); pass++; }
else { print("FAIL: indirect eval expected 3 got " + r15); fail++; }

// --- Test 16: eval SyntaxError catchable via try/catch ---
try {
    eval("var @#$");
    print("FAIL: eval syntax error should throw");
    fail++;
} catch(e) {
    if (e.message !== undefined) { print("PASS: eval SyntaxError caught"); pass++; }
    else { print("FAIL: eval SyntaxError missing message"); fail++; }
}

// --- Test 17: eval SyntaxError via indirect eval ---
try {
    indirect_eval("if (true) { ");
    print("FAIL: indirect eval syntax error should throw");
    fail++;
} catch(e) {
    if (e.message !== undefined) { print("PASS: indirect eval SyntaxError caught"); pass++; }
    else { print("FAIL: indirect eval SyntaxError missing message"); fail++; }
}

// --- Test 18: eval via Function.prototype.call ---
try {
    eval.call(null, "var @#$");
    print("FAIL: eval.call should throw");
    fail++;
} catch(e) {
    if (e.message !== undefined) { print("PASS: eval.call SyntaxError caught"); pass++; }
    else { print("FAIL: eval.call SyntaxError missing message"); fail++; }
}

// --- Test 19: eval via Function.prototype.apply ---
try {
    eval.apply(null, ["var @#$"]);
    print("FAIL: eval.apply should throw");
    fail++;
} catch(e) {
    if (e.message !== undefined) { print("PASS: eval.apply SyntaxError caught"); pass++; }
    else { print("FAIL: eval.apply SyntaxError missing message"); fail++; }
}

// --- Test 20: eval via bind ---
var bound_eval = eval.bind(null);
try {
    bound_eval("var @#$");
    print("FAIL: bound eval should throw");
    fail++;
} catch(e) {
    if (e.message !== undefined) { print("PASS: bound eval SyntaxError caught"); pass++; }
    else { print("FAIL: bound eval SyntaxError missing message"); fail++; }
}

// --- Test 21: eval via double bind (nested bound function) ---
var double_bound = eval.bind(null).bind(null);
try {
    double_bound("var @#$");
    print("FAIL: double-bound eval should throw");
    fail++;
} catch(e) {
    if (e.message !== undefined) { print("PASS: double-bound eval SyntaxError caught"); pass++; }
    else { print("FAIL: double-bound eval SyntaxError missing message"); fail++; }
}

print("=== All eval tests done: " + pass + " passed, " + fail + " failed ===");
