// Annex B.3.2 / ES2024 §18.2.1.2: `delete` on a var-declared binding.
//
// A sloppy direct eval shares its caller's variable environment, so a
// function's own `var` and a binding the eval itself declares live in the
// same env record. Only the latter is configurable
// (CreateMutableBinding(N, true)); deleting the former must report false and
// leave the binding intact. Getting this wrong removed a live binding and
// turned every later read of it into a ReferenceError.
var passed = 0, failed = 0;
function eq(actual, expected, what) {
    if (actual === expected) { passed++; return; }
    failed++;
    print("FAIL: " + what + " -> got " + String(actual) + ", want " + String(expected));
}

// A function-scope var survives `delete` and keeps its value.
(function () {
    var x = 1, y = 2;
    eq(eval("delete x"), false, "delete fn var returns false");
    eq(typeof x, "number", "deleted fn var still bound");
    eq(x, 1, "deleted fn var keeps its value");
    eq(y, 2, "sibling var untouched");
})();

// Parameters are var-scoped bindings and behave the same.
(function (p) {
    eq(eval("delete p"), false, "delete param returns false");
    eq(typeof p, "number", "deleted param still bound");
    eq(p, 7, "deleted param keeps its value");
})(7);

// A var in an enclosing function, reached from a nested function's eval.
(function () {
    var o = 1;
    (function () {
        eq(eval("delete o"), false, "delete enclosing var returns false");
    })();
    eq(o, 1, "enclosing var keeps its value");
})();

// let/const are lexical, never deletable.
(function () {
    let l = 1;
    const c = 2;
    eq(eval("delete l"), false, "delete let returns false");
    eq(l, 1, "let keeps its value");
    eq(eval("delete c"), false, "delete const returns false");
    eq(c, 2, "const keeps its value");
})();

// A binding the eval itself declares IS configurable and really goes away.
(function () {
    eq(eval("var ev = 1; delete ev"), true, "delete eval-created var returns true");
    eq(typeof ev, "undefined", "eval-created var is gone");
})();

// A function declared inside eval is likewise configurable.
(function () {
    eq(eval("function ef(){} delete ef"), true, "delete eval-created fn returns true");
    eq(typeof ef, "undefined", "eval-created fn is gone");
})();

// An inner function declaration is NOT eval-created: not deletable.
(function () {
    function inner() {}
    eq(eval("delete inner"), false, "delete inner fn decl returns false");
    eq(typeof inner, "function", "inner fn decl survives");
})();

// `arguments` is bound non-deletably.
(function () {
    eq(eval("delete arguments"), false, "delete arguments returns false");
    eq(typeof arguments, "object", "arguments survives");
})();

// Unresolvable names report true in sloppy mode.
(function () {
    eq(eval("delete no_such_binding_at_all"), true, "delete undeclared returns true");
})();

// `with` makes delete a property delete, which does remove it.
(function () {
    var ob = { w: 1 };
    var res;
    with (ob) { res = eval("delete w"); }
    eq(res, true, "delete with-object prop returns true");
    eq("w" in ob, false, "with-object prop removed");
})();

// Without eval, the direct form agrees.
(function () {
    var d = 1;
    eq(delete d, false, "direct delete var returns false");
    eq(typeof d, "number", "direct delete leaves binding");
})();

// A global var is non-configurable; a global created by assignment is not.
var global_var = 1;
eq(eval("delete global_var"), false, "delete global var returns false");
eq(global_var, 1, "global var keeps its value");
implicit_global = 2;
eq(eval("delete implicit_global"), true, "delete implicit global returns true");

print(failed === 0
    ? "PASS (" + passed + " assertions)"
    : "FAILED " + failed + " of " + (passed + failed));
