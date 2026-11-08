// Outward-facing facts of a deferred function body must survive deferral: names a
// body references from an enclosing scope mark those bindings captured, and a
// direct `eval` or `with` inside a body taints the scopes around it. Eval compiles
// ordinary bodies as deferred templates, so this guards the resolver's use of the
// parser-side body records: the enclosing compile still has to heap-allocate and
// share exactly what the deferred code reaches.

var failures = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// ---- capture of an outer variable ----
(function () {
    var n = 0;
    var inc = function () { n++; };      // deferred body writes an outer `var`
    inc(); inc();
    check("closure writes outer var", n, 2);

    function make() { var c = 100; return function () { return c; }; }
    check("closure reads outer var", make()(), 100);

    function counter() {
        var count = 0;
        return function () { count += 1; return count; };
    }
    var step = counter();
    step(); step();
    check("closure returns outer var", step(), 3);
})();

(function () {
    // A nested declaration body writing an outer `var`.
    var target = 0;
    function outer() {
        function inner() { target = 42; }
        inner();
    }
    outer();
    check("nested function writes outer var", target, 42);
})();

(function () {
    // A write to a formal parameter captured by a nested body.
    function outer(p) {
        var bump = function () { p += 1; return p; };
        bump();
        return bump;
    }
    check("closure writes outer formal", outer(5)(), 7);
})();

// ---- capture across an eval boundary ----
(function () {
    var saved = (0, eval)('(function(x) { return function() { return x; }; })')(23);
    for (var i = 0; i < 20; i++) (0, eval)('(function(x) { return x + 1; })')(i);
    check("eval closure keeps its environment", saved(), 23);
})();

(function () {
    // Top-level lexical block captured by a function defined inside eval.
    (0, eval)('{ let secret = 17; globalThis.__capSecret = function() { return secret; }; }');
    check("eval closure reads a lexical block", __capSecret(), 17);
    delete globalThis.__capSecret;
})();

// ---- direct eval inside a deferred body reaches enclosing bindings ----
(function () {
    var visible = 7;
    function readsViaEval() {
        return eval("visible");          // DIRECT eval: must see `visible`
    }
    check("direct eval sees an outer binding", readsViaEval(), 7);
})();

// ---- `with` inside a deferred body makes name lookup dynamic ----
(function () {
    // `loc` must be resolved through the `with` object when present, and through
    // the function's own binding otherwise. If `with` taint were lost in
    // deferral, `loc` would be frozen to the local and g({loc:5}) would return
    // 101 instead of 6.
    function g(o) {
        var loc = 100;
        with (o) { return loc + 1; }
    }
    check("with: name absent from the object falls through", g({}), 101);
    check("with: name present on the object shadows the local", g({ loc: 5 }), 6);
})();

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred body capture: OK");
