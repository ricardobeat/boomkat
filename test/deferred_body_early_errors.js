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

// ---- declarations in single-statement positions ----
rejects("function as a while body", "function f(){ while (0) function g(){} }");
rejects("function as a for body", "function f(){ for (;;) function g(){} }");
rejects("function as a with body", "function f(){ with ({}) function g(){} }");
rejects("class as an if body", "function f(){ if (1) class C {} }");
rejects("const as an if body", "function f(){ if (1) const a = 1; }");
rejects("async function as an if body", "function f(){ if (1) async function g(){} }");
rejects("labelled async function", "function f(){ a: async function g(){} }");
rejects("labelled function in an if body", "function f(){ if (1) a: function g(){} }");

// ---- for-head initializers ----
rejects("for-in let with initializer", "function f(){ for (let x = 1 in {}) {} }");
rejects("for-of const with initializer", "function f(){ for (const x = 1 of []) {} }");
rejects("for-of var with initializer", "function f(){ for (var x = 1 of []) {} }");
rejects("for-in var pattern with initializer", "function f(){ for (var [x] = 1 in {}) {} }");
accepts("annex B for-in var with initializer", "function f(){ for (var x = 1 in {}) {} }");

// ---- catch parameter duplicate bound names ----
rejects("duplicate catch array bindings", "function f(){ try {} catch ([a, a]) {} }");
rejects("duplicate catch object bindings", "function f(){ try {} catch ({a, a}) {} }");
rejects("duplicate catch nested bindings", "function f(){ try {} catch ({x:[a], y:a}) {} }");

// ---- using declarations are lexical ----
rejects("using then let", "function f(){ { using x = 1; let x; } }");
rejects("using then var", "function f(){ using x = 1; var x; }");
rejects("duplicate using", "function f(){ { using x = 1; using x = 2; } }");
rejects("using then class", "function f(){ { using x = 1; class x {} } }");

// ---- lexical binding names and switch defaults ----
rejects("let named let", "function f(){ let let = 1; }");
rejects("const named let", "function f(){ const let = 1; }");
rejects("destructured let named let", "function f(){ let [let] = []; }");
rejects("duplicate default clause", "function f(){ switch (0) { default: default: } }");
rejects("class named eval", "function f(){ class eval {} }");
rejects("class named arguments", "function f(){ class arguments {} }");
rejects("class named let", "function f(){ class let {} }");

// ---- nested eager bodies are validated at eval time ----
rejects("dup let in a nested strict body", "function f(){ function g(){ 'use strict'; let a; let a; } }");
rejects("dup let in a nested generator", "function f(){ function* g(){ let a; let a; } }");
rejects("dup let in a nested method", "function f(){ ({ m(){ let a; let a; } }) }");
rejects("dup let in a nested class method", "function f(){ class C { m(){ let a; let a; } } }");
rejects("break in a nested arrow", "function f(){ var g = () => { break; }; }");
rejects("with in a nested strict body", "function f(){ function g(){ 'use strict'; with({}){} } }");
rejects("var eval in a nested strict body", "function f(){ function g(){ 'use strict'; var eval = 1; } }");
rejects("arguments in a class field", "function f(){ class C { x = arguments; } }");
rejects("var eval in a class static block", "function f(){ class C { static { var eval = 1; } } }");

// ---- labels survive a nested deferred body, and chains are loop labels ----
accepts("label survives a nested body", "function f(){ a: { function inner(){} break a; } }");
accepts("nested label does not collide", "function f(){ a: { function inner(){ b: while(0){ break b; } } break a; } }");
rejects("duplicate label across a nested body", "function f(){ a: { function inner(){} a: ; } }");
accepts("continue to an outer label of a chain", "function f(){ a: b: while (0) { continue a; } }");
accepts("annex B if-function with a later let", "function f(){ if (1) function g(){} let g; }");
accepts("annex B if-function with a later class", "function f(){ if (1) function g(){} class g {} }");

// ---- sanity: valid deferred bodies are still accepted ----
accepts("valid uncalled body", "function f(){ let x; return x + 1; }");
accepts("valid nested capture", "var n = 0; function outer(){ function inner(){ n++; } return inner; }");
accepts("valid super.x in a method", "var o = { m(){ return super.toString; } };");
accepts("valid arrow inheriting super", "var o = { m(){ var f = () => super.toString; return f(); } };");

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred body early errors: OK");
