// A named FunctionExpression binds its own name only inside its own body
// (ES2024 §15.2.5), so the hoist pre-scan must not declare that name as a var
// in the enclosing scope. When it did, an argument referring to a same-named
// enclosing binding resolved to the function object instead (mathjs passed its
// factory function where an array of factories was expected).

function check(label, got, want) {
    if (got !== want) {
        print("FAIL " + label + ": got " + got + ", want " + want);
    }
}

function paren_call(e) { (function e(n) {})(e); return typeof e; }
check("paren call", paren_call([1]), "object");

function bang_call(e) { !function e(n) {}(e); return typeof e; }
check("bang call", bang_call([1]), "object");

function void_call(e) { void function e(n) {}(e); return typeof e; }
check("void call", void_call([1]), "object");

function in_array(e) { [function e(n) {}]; return typeof e; }
check("array element", in_array([1]), "object");

function in_object(e) { ({ k: function e(n) {} }); return typeof e; }
check("object value", in_object([1]), "object");

function assigned(e) { var z = function e(n) {}; return typeof e; }
check("assigned", assigned([1]), "object");

function comma_seq(e) { !function e(n) {}(0), 1; return typeof e; }
check("comma sequence", comma_seq([1]), "object");

// The argument really is the enclosing binding, not the function object.
function passes_value(e) {
    var seen;
    (function e(n) { seen = n; })(e);
    return Array.isArray(seen) && seen[0] === 7;
}
check("argument value", passes_value([7]), true);

// The name still binds inside the expression's own body.
function self_ref() { return (function e() { return typeof e; })(); }
check("self reference", self_ref(), "function");

// A real FunctionDeclaration still hoists, including after another
// declaration's body (whose closing '}' the pre-scan never sees as a token).
function decl_hoisted() { return typeof f; function f() {} }
check("declaration hoisted", decl_hoisted(), "function");

function decl_after_decl() {
    var r = typeof second;
    function first() {}
    function second() {}
    return r;
}
check("declaration after declaration", decl_after_decl(), "function");

function decl_after_class() {
    var r = typeof g;
    class C {}
    function g() {}
    return r;
}
check("declaration after class", decl_after_class(), "function");

function async_decl_hoisted() { return typeof a; async function a() {} }
check("async declaration hoisted", async_decl_hoisted(), "function");

function gen_decl_hoisted() { return typeof s; function* s() {} }
check("generator declaration hoisted", gen_decl_hoisted(), "function");

// A named function expression whose body contains `var` must not leak it.
function no_var_leak(e) {
    (function e(n) { var leaked = 1; return leaked; })(e);
    return typeof leaked;
}
check("no var leak", no_var_leak([1]), "undefined");

print("named_func_expr_scope: done");
