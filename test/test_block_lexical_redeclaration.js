// Early error: the LexicallyDeclaredNames of a BlockStatement must not contain
// duplicate entries (ES2024 §13.2.1).
//
// let, const, class and FunctionDeclaration all contribute lexical names to the
// enclosing block, so any two of them sharing a name in the SAME block is a
// SyntaxError. The engine caught let/const/class collisions at their
// declaration site, but function declarations never reached that path, so
// `{ function f(){} class f{} }` and `{ let x; function x(){} }` were accepted.
//
// The one exception is §B.3.2.1: two PLAIN FunctionDeclarations may share a
// name in a block. That relaxation covers only that pair — `function` with
// `function*`, with `async function`, with `class` or with `let` all remain
// errors, so the check has to distinguish a plain function from the others
// rather than exempting "anything declared with the function keyword".

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

// Every declaration form that binds a lexical name in a block. The second
// element says whether the form is a plain FunctionDeclaration (the only form
// that may legally pair with another of its own kind).
var forms = [
    ["let x;",                 false],
    ["const x = 1;",           false],
    ["class x {}",             false],
    ["function x() {}",        true],
    ["function* x() {}",       false],
    ["async function x() {}",  false],
    ["async function* x() {}", false]
];

for (var i = 0; i < forms.length; i++) {
    for (var j = 0; j < forms.length; j++) {
        var a = forms[i], b = forms[j];
        var src = "{ " + a[0] + " " + b[0] + " }";
        // Legal only when BOTH are plain FunctionDeclarations.
        var bothPlainFunctions = a[1] && b[1];
        assert(syntaxError(src) !== bothPlainFunctions,
               (bothPlainFunctions ? "must accept " : "must reject ") + src);
    }
}

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
