// Early error: a "use strict" directive is forbidden in the body of a function
// whose FormalParameters are not simple (ES2024 §15.2.1 and the parallel
// clauses for generators, async functions, methods and arrows).
//
// IsSimpleParameterList (§15.1.3) is false when any parameter is a rest
// element, carries an initializer, or is a destructuring pattern.
//
// This engine is strict-only and treats "use strict" as an accepted no-op, so
// nothing downstream depends on the directive — but the early error must still
// fire, and it must fire for ALL function forms, not just the `function`
// keyword ones. Arrow bodies in particular used to skip directive-prologue
// parsing entirely.

function syntaxError(source) {
    try {
        eval(source);
        return false;
    } catch (e) {
        return e instanceof SyntaxError;
    }
}

var pass = 0;
var fail = 0;
function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL: " + msg);
    }
}

// Each non-simple parameter list, across each function form.
var nonSimpleParams = ["a, ...rest", "...rest", "a = 1", "[a]", "{a}", "a, b = 2"];

for (var i = 0; i < nonSimpleParams.length; i++) {
    var p = nonSimpleParams[i];

    assert(syntaxError("(function (" + p + ") { 'use strict'; });"),
           "function expression with params (" + p + ")");
    assert(syntaxError("function fn_" + i + "(" + p + ") { 'use strict'; }"),
           "function declaration with params (" + p + ")");
    assert(syntaxError("(function* (" + p + ") { 'use strict'; });"),
           "generator with params (" + p + ")");
    assert(syntaxError("(async function (" + p + ") { 'use strict'; });"),
           "async function with params (" + p + ")");
    assert(syntaxError("(async function* (" + p + ") { 'use strict'; });"),
           "async generator with params (" + p + ")");
    assert(syntaxError("({ m(" + p + ") { 'use strict'; } });"),
           "object method with params (" + p + ")");
    assert(syntaxError("({ *m(" + p + ") { 'use strict'; } });"),
           "generator method with params (" + p + ")");
    assert(syntaxError("({ async m(" + p + ") { 'use strict'; } });"),
           "async method with params (" + p + ")");
    assert(syntaxError("(class { m(" + p + ") { 'use strict'; } });"),
           "class method with params (" + p + ")");
    assert(syntaxError("(class { constructor(" + p + ") { 'use strict'; } });"),
           "class constructor with params (" + p + ")");
    assert(syntaxError("((" + p + ") => { 'use strict'; });"),
           "arrow with params (" + p + ")");
    assert(syntaxError("(async (" + p + ") => { 'use strict'; });"),
           "async arrow with params (" + p + ")");
}

// A setter takes exactly one parameter, so it gets its own cases.
assert(syntaxError("({ set x(a = 1) { 'use strict'; } });"),
       "setter with a default parameter");
assert(syntaxError("({ set x([a]) { 'use strict'; } });"),
       "setter with an array pattern parameter");
assert(syntaxError("({ set x({a}) { 'use strict'; } });"),
       "setter with an object pattern parameter");

// The directive is still a directive without a trailing semicolon: ASI ends
// the statement at the closing brace.
assert(syntaxError("(function (a = 1) { 'use strict' });"),
       "directive terminated by ASI at the closing brace");
assert(syntaxError("((a = 1) => { 'use strict' });"),
       "arrow directive terminated by ASI at the closing brace");
assert(syntaxError("(function (a = 1) {\n  'use strict'\n});"),
       "directive terminated by ASI at a line break");

// --- Must STILL be accepted (over-rejection guard) -------------------------
// A simple parameter list may carry the directive in every form.
assert(!syntaxError("(function () { 'use strict'; });"), "no parameters");
assert(!syntaxError("(function (a) { 'use strict'; });"), "one plain parameter");
assert(!syntaxError("(function (a, b) { 'use strict'; });"), "two plain parameters");
assert(!syntaxError("(function* (a) { 'use strict'; });"), "generator, plain parameter");
assert(!syntaxError("(async function (a) { 'use strict'; });"), "async fn, plain parameter");
assert(!syntaxError("({ m(a) { 'use strict'; } });"), "method, plain parameter");
assert(!syntaxError("({ set x(a) { 'use strict'; } });"), "setter, plain parameter");
assert(!syntaxError("(class { m(a) { 'use strict'; } });"), "class method, plain parameter");
assert(!syntaxError("(() => { 'use strict'; });"), "arrow, no parameters");
assert(!syntaxError("((a) => { 'use strict'; });"), "arrow, one plain parameter");
assert(!syntaxError("(a => { 'use strict'; });"), "arrow, unparenthesized parameter");
assert(!syntaxError("(async (a) => { 'use strict'; });"), "async arrow, plain parameter");

// Non-simple parameters are fine as long as there is no directive.
assert(!syntaxError("(function (a = 1) { });"), "default parameter, empty body");
assert(!syntaxError("(function (a = 1) { return a; });"), "default parameter, no directive");
assert(!syntaxError("(function (...r) { return r; });"), "rest parameter, no directive");
assert(!syntaxError("(function ([a]) { return a; });"), "array pattern, no directive");
assert(!syntaxError("(function ({a}) { return a; });"), "object pattern, no directive");
assert(!syntaxError("((a = 1) => { return a; });"), "arrow default, no directive");
assert(!syntaxError("(([a]) => { return a; });"), "arrow array pattern, no directive");

// A string that is not the "use strict" directive is just an expression.
assert(!syntaxError("(function (a = 1) { 'not strict'; });"), "unrelated directive string");
assert(!syntaxError("(function (a = 1) { 'use strict '; });"), "trailing space, not the directive");
assert(!syntaxError("(function (a = 1) { 'use  strict'; });"), "double space, not the directive");

// "use strict" outside the directive prologue is an ordinary expression
// statement and carries no early error.
assert(!syntaxError("(function (a = 1) { 0; 'use strict'; });"),
       "string after a non-directive statement");
assert(!syntaxError("(function (a = 1) { { 'use strict'; } });"),
       "string inside a nested block");
assert(!syntaxError("(function (a = 1) { return 'use strict'; });"),
       "string as a return value");
assert(!syntaxError("(function (a = 1) { let s = 'use strict'; });"),
       "string as an initializer");
assert(!syntaxError("((a = 1) => 'use strict');"),
       "arrow expression body returning the string");

// The rule is per-function: an inner function with SIMPLE parameters may carry
// the directive even when the OUTER function's parameters are not simple.
assert(!syntaxError("(function (a = 1) { function g() { 'use strict'; } });"),
       "inner function with simple params inside a non-simple outer");
assert(!syntaxError("(function (a) { 'use strict'; function g(b = 1) { } });"),
       "non-simple inner params, directive on the simple outer");

// --- The directive must still be a no-op at program and eval level ---------
assert(!syntaxError("'use strict'; var q1 = 1;"), "directive at program level");
assert(!syntaxError("'use strict'"), "bare directive, ASI at end of program");

// --- Functions with non-simple params must still WORK ----------------------
var f1 = function (a = 7) { return a; };
assert(f1() === 7, "default parameter still applies");
assert(f1(3) === 3, "explicit argument still overrides the default");
var f2 = function (...r) { return r.length; };
assert(f2(1, 2, 3) === 3, "rest parameter still collects arguments");
var f3 = function ({ a }) { return a; };
assert(f3({ a: 5 }) === 5, "object pattern parameter still destructures");
var f4 = ([a, b]) => a + b;
assert(f4([1, 2]) === 3, "arrow array pattern still destructures");
var f5 = function (a) { "use strict"; return a * 2; };
assert(f5(4) === 8, "simple params with a directive still run");
var f6 = () => { "use strict"; return 9; };
assert(f6() === 9, "arrow with a directive still runs");

print('use-strict-non-simple-params: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
