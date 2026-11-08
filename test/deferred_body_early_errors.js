// Early errors inside a function body that is NEVER called must still throw a
// SyntaxError when the surrounding code is evaluated (ECMA-262: every syntax and
// early error is reported at parse/eval time, independent of whether the function
// runs). Eval compiles ordinary function bodies as deferred templates, so this
// also guards the frontend's deferred-body path: skipping a body must not lose
// its grammar or early-error validation.
//
// Each case is a source string with a single defect inside a function body. The
// function is created but never invoked; the assertion is that `eval` itself
// throws, and throws a SyntaxError.

var failures = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Evaluate `src`, returning the error kind it produced.
function evalResult(src) {
    try {
        (0, eval)(src);
        return "no-throw";
    } catch (e) {
        return e instanceof SyntaxError ? "SyntaxError" : ("throw:" + (e && e.name));
    }
}

// A defect inside an uncalled function body must be a SyntaxError at eval time.
function rejects(name, body) {
    check(name, evalResult(body), "SyntaxError");
}

// Sanity: a valid uncalled deferred body is NOT rejected (so the battery is not
// passing merely because every eval throws).
function accepts(name, body) {
    check(name, evalResult(body), "no-throw");
}

// ---- duplicate / conflicting declarations ----
rejects("duplicate let in a body", "function f(){ let x; let x; }");
rejects("let then const", "function f(){ let x; const x = 1; }");
rejects("const then let", "function f(){ const x = 1; let x; }");
rejects("let then var", "function f(){ let x; var x; }");
rejects("var then let", "function f(){ var x; let x; }");
rejects("let then class", "function f(){ let x; class x {} }");
rejects("class then let", "function f(){ class x {} let x; }");
rejects("duplicate const", "function f(){ const x = 1; const x = 2; }");
rejects("duplicate in nested block", "function f(){ { let y; let y; } }");
rejects("duplicate in nested function body", "function outer(){ function inner(){ let x; let x; } }");
rejects("unnamed expression body duplicate", "(function(){ let x; let x; })");
rejects("function declaration redeclared by let", "function f(){ function g(){} let g; }");

// ---- const with no initializer ----
rejects("const without initializer", "function f(){ const x; }");
rejects("const without initializer in block", "function f(){ { const y; } }");

// ---- super misuse in nested plain functions ----
rejects("super.x in a nested plain function", "var o = { m: function(){ function foo(){ return super.toString; } return foo(); } };");
rejects("super() in a nested plain function", "function f(){ function foo(){ super(); } return foo(); }");

// ---- invalid assignment targets ----
rejects("assignment to a literal", "function f(){ 1 = 2; }");
rejects("assignment to `this`", "function f(){ this = 1; }");
rejects("logical assignment to a call", "function f(){ g() &&= 1; }");

// ---- operator / literal grammar errors ----
rejects("nullish mixed with &&", "function f(){ a ?? b && c; }");
rejects("nullish mixed with ||", "function f(){ a || b ?? c; }");
rejects("duplicate __proto__ fields", "function f(){ ({ __proto__: 1, __proto__: 2 }); }");
rejects("invalid regular expression literal", "function f(){ /(/; }");

// ---- control-flow / label errors ----
rejects("break outside a loop or label", "function f(){ break; }");
rejects("continue outside a loop", "function f(){ continue; }");
rejects("duplicate label", "function f(){ l: l: ; }");

// ---- sanity: valid deferred bodies are still accepted ----
accepts("valid uncalled body", "function f(){ let x; return x + 1; }");
accepts("valid nested capture", "var n = 0; function outer(){ function inner(){ n++; } return inner; }");
accepts("valid super.x in a method", "var o = { m(){ return super.toString; } };");
accepts("valid arrow inheriting super", "var o = { m(){ var f = () => super.toString; return f(); } };");

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred body early errors: OK");
