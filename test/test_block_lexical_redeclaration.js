"use strict";
// Early error: the LexicallyDeclaredNames of a BlockStatement must not contain
// duplicate entries (ES2024 §13.2.1).
//
// The explicit directive is for portability only: this engine is strict-only,
// but a direct `eval` in node inherits the CALLER's strictness, and node does
// not make a CommonJS entry point strict without it. Without the directive the
// eval'd probes below would be sloppy under node and Annex B would apply.
//
// let, const, class and FunctionDeclaration all contribute lexical names to the
// enclosing block, so any two of them sharing a name in the SAME block is a
// SyntaxError. The engine caught let/const/class collisions at their
// declaration site, but function declarations never reached that path, so
// `{ function f(){} class f{} }` and `{ let x; function x(){} }` were accepted.
//
// Annex B relaxes this for a pair of plain FunctionDeclarations, but only in
// sloppy-mode code. This engine is strict-only, so that relaxation never
// applies and `{ function f(){} function f(){} }` is a SyntaxError like every
// other pairing — matching test262's onlyStrict parse-negatives generated from
// the `redeclare-allow-sloppy-function` templates.
//
// Runs unmodified under node (`node test/test_block_lexical_redeclaration.js`)
// with the same counts; a `print` shim is defined below when absent.

if (typeof print === "undefined") {
    var print = function (s) { console.log(s); };
}

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

// Every declaration form that binds a lexical name in a block. In a block, ALL
// of these are LexicallyDeclaredNames, so any two sharing a name is a
// SyntaxError with no exceptions. Annex B's relaxation for a pair of plain
// FunctionDeclarations is sloppy-mode only and this engine is strict-only, so
// `{ function x(){} function x(){} }` is rejected here too — which is what
// test262's onlyStrict redeclare-allow-sloppy-function tests require.
var forms = [
    "let x;",
    "const x = 1;",
    "class x {}",
    "function x() {}",
    "function* x() {}",
    "async function x() {}",
    "async function* x() {}"
];

for (var i = 0; i < forms.length; i++) {
    for (var j = 0; j < forms.length; j++) {
        var src = "{ " + forms[i] + " " + forms[j] + " }";
        assert(syntaxError(src), "must reject " + src);
    }
}

// A function BODY is not a block for this rule: its top-level function
// declarations are var-scoped, so duplicates there stay legal even in strict
// code. Only a genuine BlockStatement/CaseBlock applies the lexical rule.
assert(!syntaxError("function fb() { function x() {} function x() {} }"),
       "duplicate functions at function-body top level");
assert(syntaxError("function fb() { { function x() {} function x() {} } }"),
       "duplicate functions in a block nested in a function body");

// A switch CaseBlock is a single StatementList spanning all clauses
// (ES2024 §14.12.1), so the same two rules apply across case/default.
assert(syntaxError("switch (0) { case 1: let x; default: class x {} }"),
       "switch CaseBlock duplicate lexical names across clauses");
assert(syntaxError("switch (0) { case 1: var x; default: let x; }"),
       "switch CaseBlock lexical name colliding with a var name");
assert(syntaxError("switch (0) { case 1: function x() {} default: function x() {} }"),
       "switch CaseBlock duplicate function declarations");
assert(!syntaxError("switch (0) { case 1: { let x; } default: { let x; } }"),
       "switch clauses' own nested blocks are separate scopes");
assert(!syntaxError("switch (0) { case 1: var x; default: var x; }"),
       "duplicate var names in a CaseBlock are legal");

// `var` colliding with a lexical binding in the same block, both orders.
assert(syntaxError("{ let x; var x; }"), "{ let x; var x; }");
assert(syntaxError("{ var x; let x; }"), "{ var x; let x; }");
assert(syntaxError("{ const x = 1; var x; }"), "{ const x = 1; var x; }");
assert(syntaxError("{ class x {} var x; }"), "{ class x {} var x; }");
assert(syntaxError("{ function x() {} var x; }"), "{ function x() {} var x; }");
assert(syntaxError("{ var x; function x() {} }"), "{ var x; function x() {} }");

// A `var` nested deeper still collides — VarDeclaredNames recurses.
assert(syntaxError("{ let a; { var a; } }"), "nested var vs outer block let");

// --- Must STILL be accepted (over-rejection guard) -------------------------
// Distinct names never collide.
assert(!syntaxError("{ let a; let b; }"), "two distinct let names");
assert(!syntaxError("{ function f() {} function g() {} }"), "two distinct functions");
assert(!syntaxError("{ class A {} class B {} }"), "two distinct classes");
assert(!syntaxError("{ let a, b, c; }"), "one let with three declarators");
assert(!syntaxError("{ const a = 1, b = 2; }"), "one const with two declarators");
assert(!syntaxError("{ let x; var y; }"), "let and var with different names");

// Different blocks are different scopes.
assert(!syntaxError("{ let x; { let x; } }"), "let shadowed in a nested block");
assert(!syntaxError("{ const c = 1; { const c = 2; } }"), "const shadowed in a nested block");
assert(!syntaxError("{ class A {} { class A {} } }"), "class shadowed in a nested block");
assert(!syntaxError("{ function f() {} { function f() {} } }"), "function in a nested block");
assert(!syntaxError("{ let x; } { let x; }"), "same name in two sibling blocks");
assert(!syntaxError("{ let x; if (1) { let x; } }"), "shadowed inside an if block");
assert(!syntaxError("{ let x; function g() { let x; } }"), "shadowed in a nested function");
assert(!syntaxError("{ let a; { var b; } }"), "nested var with a different name");

// A function BODY's top-level function declarations are var-scoped, not
// lexical, so redeclaring them there is allowed.
assert(!syntaxError("function o1() { function f() {} function f() {} }"),
       "duplicate functions at function-body top level");
assert(!syntaxError("function o2() { var x; function x() {} }"),
       "var and function with the same name in a function body");

// A NAMED class or function EXPRESSION binds its name only inside itself, so
// it is not a block-level lexical name and cannot collide with one. These
// regressed when the initializer was mistakenly scanned at statement position.
assert(!syntaxError("{ let x = class x {}; }"), "let initialized by a same-named class expression");
assert(!syntaxError("{ let y = function y() {}; }"), "let initialized by a same-named function expression");
assert(!syntaxError("{ const c = class c {}; }"), "const initialized by a same-named class expression");
assert(!syntaxError("{ let a = class A {}, b = class B {}; }"), "two class-expression initializers");
assert(!syntaxError("{ let x, y = class y {}; }"), "declarator list ending in a class expression");
assert(!syntaxError("{ let f = function g() {}; function g() {} }"),
       "function expression's name does not collide with a later declaration");
assert(!syntaxError("{ f(class C {}); class C {} }"), "class expression as a call argument");
assert(!syntaxError("{ let arr = [class x {}]; }"), "class expression inside an array literal");
assert(!syntaxError("{ let o = { m: class m {} }; }"), "class expression as a property value");
assert(!syntaxError("{ let t = true ? class p {} : 0; }"), "class expression in a ternary");
assert(!syntaxError("{ let s = 'class x {}'; class x {} }"), "class name only inside a string");

// Other initializer shapes must not confuse the scan either.
assert(!syntaxError("{ let a = [1,2], b = {c:3}; }"), "array and object initializers");
assert(!syntaxError("{ let n = 1; let m = n; }"), "initializer referring to an earlier binding");
assert(!syntaxError("{ let x = () => { let x; }; }"), "arrow body shadowing its own binding");
assert(!syntaxError("{ let x = 1; function y() {} }"), "let and a differently-named function");
assert(!syntaxError("{ let obj = { f: 1, f: 2 }; }"), "duplicate object literal keys are not bindings");
assert(!syntaxError("{ let x; ({ x: 1 }); }"), "object literal key matching a let name");

// Switch case blocks and other statement positions still work.
assert(!syntaxError("switch (1) { case 1: let x; break; }"), "let in a case block");
assert(!syntaxError("switch (1) { case 1: let x; break; case 2: let y; break; }"),
       "distinct let names across case clauses");
assert(!syntaxError("{ try { let e; } catch (e) { let f; } }"), "catch parameter and block let");
assert(!syntaxError("{ for (let i = 0; i < 1; i++) { let j; } }"), "for-head let and body let");
assert(!syntaxError("{ label: { let x; } let y; }"), "labelled block followed by a let");

// --- Declarations must still WORK ------------------------------------------
{
    let a = 1;
    const b = 2;
    class C { m() { return 3; } }
    function d() { return 4; }
    assert(a === 1, "let binding still holds its value");
    assert(b === 2, "const binding still holds its value");
    assert(new C().m() === 3, "class declaration still usable");
    assert(d() === 4, "function declaration still callable");
}
{
    let x = 1;
    { let x = 2; assert(x === 2, "inner block shadow reads the inner binding"); }
    assert(x === 1, "outer binding is intact after the inner block");
}
{
    let K = class K { static who() { return "K"; } };
    assert(K.who() === "K", "self-named class expression still resolves its own name");
}

print('block-lexical-redeclaration: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
