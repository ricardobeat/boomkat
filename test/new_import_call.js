// `new import(...)` is a SyntaxError (ES2024 §13.3).
//
// The callee of a NewExpression is a MemberExpression, and an ImportCall is a
// CallExpression — a production MemberExpression does not derive. So
// `new import('')` is invalid wherever it appears, however deeply nested, and
// however it is reached (a return value, an `await` operand, an arrow body).
//
// Two things stay legal and must not be caught by this: `import.meta`, which
// is a MemberExpression, and `new (import(''))`, where the parentheses make
// the call a PrimaryExpression.
//
// Runs unmodified under node (`node test/new_import_call.js`) with the shim
// below, so the expectations are V8-verified.
if (typeof print === "undefined") { var print = function (s) { console.log(s); }; }

var pass = 0;
var fail = 0;

// Every source is compiled inside a never-called function so that a runtime
// failure (an unresolvable module specifier) can never be mistaken for the
// parse failure we are actually testing.
function rejects(label, src) {
    var threw = false;
    try {
        Function('"use strict";\nfunction __never() {\n' + src + '\n}');
    } catch (e) {
        threw = (e instanceof SyntaxError);
    }
    if (threw) { pass++; }
    else { fail++; print("FAIL: expected SyntaxError for " + label + " -- [" + src + "]"); }
}

function accepts(label, src) {
    try {
        Function('"use strict";\nfunction __never() {\n' + src + '\n}');
        pass++;
    } catch (e) {
        fail++;
        print("FAIL: expected " + label + " to parse -- [" + src + "] threw " + e);
    }
}

// --- `new import(...)` is invalid in every statement position ---
rejects("top level",              "new import('');");
rejects("in a block",             "{ new import(''); }");
rejects("in a labelled block",    "label: { new import(''); }");
rejects("in an if body",          "if (true) new import('');");
rejects("in an if block",         "if (true) { new import(''); }");
rejects("in a braceless else",    "if (false) {} else new import('');");
rejects("in an else block",       "if (false) {} else { new import(''); }");
rejects("in a while body",        "let x = 0; while (!x) { x++; new import(''); }");
rejects("in a do-while body",     "do { new import(''); } while (false);");
rejects("in a for body",          "for (;;) { new import(''); }");
rejects("in a function body",     "function fn() { new import(''); }");
rejects("as a function return",   "function fn() { return new import(''); }");
rejects("in an arrow body",       "let f = () => { new import(''); };");
rejects("as an arrow expression", "let f = () => new import('');");
rejects("with a second argument", "new import('', {});");

// --- ...including behind `await`, where the operand is still a UnaryExpression
rejects("awaited in an async fn",     "async function f() { await new import(''); }");
rejects("returned awaited async fn",  "async function f() { return await new import(''); }");
rejects("awaited in an async arrow",  "(async () => { await new import('') });");
rejects("returned from async arrow",  "(async () => await new import(''));");
rejects("awaited in an async gen",    "async function * f() { await new import('') }");

// --- ACCEPT side: dynamic import itself, and `new` generally, must still work ---
accepts("plain dynamic import",       "import('');");
accepts("dynamic import in a block",  "{ import(''); }");
accepts("dynamic import in a fn",     "function f() { return import(''); }");
accepts("dynamic import in an arrow", "let f = () => import('');");
accepts("awaited dynamic import",     "async function f() { await import(''); }");
accepts("awaited in an async arrow",  "(async () => await import(''));");
accepts("dynamic import .then",       "import('').then(function () {});");
accepts("dynamic import two args",    "import('', {});");
accepts("dynamic import in template", "`${import('')}`;");
accepts("dynamic import as argument", "function g(x){} g(import(''));");
// Parenthesising the call makes it a PrimaryExpression, which `new` accepts.
accepts("new of a parenthesized import", "new (import(''));");
accepts("new of a covered expression",   "new (import(''), function () {});");
// ...and ordinary `new` forms are untouched.
accepts("new of a plain callee",      "function C(){} new C();");
accepts("new of a member callee",     "var o = { C: function(){} }; new o.C();");
accepts("new of a call result",       "function f(){ return { C: function(){} }; } new (f().C)();");
accepts("nested new",                 "function C(){} new new C()();");
accepts("new Function",               "new Function('');");

// --- the covered form must still WORK at runtime, not merely parse ---
function runtimeEquals(label, src, expected) {
    var got;
    try {
        got = String(Function('"use strict";\n' + src)());
    } catch (e) {
        got = "threw " + e;
    }
    if (got === expected) { pass++; }
    else { fail++; print("FAIL: " + label + " -- expected [" + expected + "] got [" + got + "]"); }
}

// `new (import(''), function () {})` — the comma operator's value is the
// function, so this constructs an ordinary object and never evaluates a module.
runtimeEquals("new of a covered expression constructs",
    "return typeof new (0, function () {});", "object");
runtimeEquals("ordinary new still constructs",
    "function C(){ this.v = 3; } return new C().v;", "3");

print("new_import_call: " + pass + " passed, " + fail + " failed");
if (fail > 0) {
    print("SOME TESTS FAILED");
    throw new Error("FAIL");
}
