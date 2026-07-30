// FormalParameters early errors for arrow functions (ES2015 §14.2.1).
//
// The arrow parameter list is parsed by its own prologue
// (compile_arrow_inner_reparse), which used to skip the restricted-name and
// duplicate-BoundName checks the function/method prologues performed. So
// `(a, a) => a` and `(eval) => 1` compiled cleanly instead of being
// SyntaxErrors. Duplicate names introduced by destructuring patterns
// (`([a], {a})`) were missed by all three prologues.
//
// Compilation errors are not catchable from the same script, so each case is
// probed with eval() — indirect via the compiler's normal entry point.

var pass = 0;
var fail = 0;

function throws(src) {
    try {
        eval(src);
    } catch (e) {
        if (e instanceof SyntaxError) {
            pass++;
            return;
        }
        fail++;
        print('FAIL (wrong error): ' + src + ' -> ' + e.constructor.name + ': ' + e);
        return;
    }
    fail++;
    print('FAIL (no throw): ' + src);
}

function accepts(src) {
    try {
        eval(src);
        pass++;
    } catch (e) {
        fail++;
        print('FAIL (rejected valid): ' + src + ' -> ' + e);
    }
}

// --- Duplicate BoundNames in arrow parameters ---
throws('var f = (a, a) => a;');
throws('var f = (a, b, a) => 1;');
throws('var f = (a, ...a) => 1;');
throws('var f = (a = 1, a) => 1;');
throws('var f = (a, a = 1) => 1;');

// Duplicates introduced by destructuring patterns, in either order.
throws('var f = ([a], {a}) => 1;');
throws('var f = ({a}, {a}) => 1;');
throws('var f = ([a], [a]) => 1;');
throws('var f = (a, {a}) => 1;');
throws('var f = ({a}, a) => 1;');
throws('var f = ([a, b, a]) => 1;');
throws('var f = ({x: a, y: a}) => 1;');
throws('var f = (a, ...{a}) => 1;');

// --- Restricted names as arrow parameters ---
throws('var f = (eval) => 1;');
throws('var f = (arguments) => 1;');
throws('var f = (a, eval) => 1;');
throws('var f = (...eval) => 1;');
throws('var f = (...arguments) => 1;');
throws('var f = ({eval}) => 1;');
throws('var f = ([eval]) => 1;');
throws('var f = ({x: arguments}) => 1;');
throws('var f = (eval = 1) => 1;');
throws('var f = (let) => 1;');
throws('var f = (yield) => 1;');

// --- Async arrows get the same checks ---
throws('var f = async (a, a) => 1;');
throws('var f = async (eval) => 1;');
throws('var f = async (arguments) => 1;');
throws('var f = async (a, ...a) => 1;');
throws('var f = async ([a], {a}) => 1;');

// --- Nested arrows and arrows in class bodies ---
throws('var f = (a) => (b, b) => 1;');
throws('var f = (a) => (eval) => 1;');
throws('class C { m() { return (a, a) => 1; } }');
throws('class C { m() { return (eval) => 1; } }');
throws('class C { f = (a, a) => 1; }');

// --- The same checks still hold for functions and methods ---
throws('function g(a, a) {}');
throws('function g(eval) {}');
throws('function g([a], {a}) {}');
throws('var o = { m(a, a) {} };');
throws('class C { m(a, a) {} }');

// --- Legitimate parameter lists must still be accepted ---
accepts('var f = (a, b) => a + b;');
accepts('var f = (a, ...b) => a;');
accepts('var f = ({a}, {b}) => a + b;');
accepts('var f = ([a], [b]) => a + b;');
accepts('var f = (a = 1, b = 2) => a + b;');
accepts('var f = (a, b = a) => a + b;');
accepts('var f = ({a: x}, {a: y}) => x + y;');
accepts('var f = ([a, [b]]) => a + b;');
accepts('var f = ([, a]) => a;');
accepts('var f = async (a, b) => a;');
accepts('var f = (a) => (b) => a + b;');
accepts('class C { m(a, b) { return (c) => a + b + c; } }');

// Shadowing a parameter in the BODY is legal — only the parameter list itself
// is checked. These must not be caught by the duplicate-name rule.
accepts('var f = (a) => { var a = 2; return a; };');
accepts('var f = (a) => { function a() {} return a; };');
accepts('var f = (a) => { try {} catch (a) {} return 1; };');
accepts('var a = 1; var f = (a) => a;');

// Values still compute correctly through the checked prologue.
var add = (a, b) => a + b;
if (add(1, 2) === 3) { pass++; } else { fail++; print('FAIL: arrow arity/value'); }

var destr = ({a}, [b]) => a + b;
if (destr({a: 1}, [2]) === 3) { pass++; } else { fail++; print('FAIL: destructured arrow value'); }

var rest = (a, ...r) => a + r.length;
if (rest(1, 2, 3) === 3) { pass++; } else { fail++; print('FAIL: rest arrow value'); }

print('arrow_param_early_errors: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
