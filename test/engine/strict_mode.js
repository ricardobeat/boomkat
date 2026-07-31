// Strict-mode semantics.
// The engine is strict-only, so these check the strict-mode rules hold rather
// than that a "use strict" directive switches them on.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// A "use strict" directive must still parse and run as a no-op.
(function () { "use strict"; return 1; })();
assert((function () { "use strict"; return 1; })() === 1, "'use strict' directive is accepted");

// Strict-mode rules: assign to undeclared var must throw
try {
    undeclaredVariable = 42;
    assert(false, "should have thrown on assignment to undeclared var");
} catch (e) {
    assert(true, "threw on undeclared assignment: " + e);
}

// Duplicate parameter names are a SyntaxError in strict code (ES5.1 s13.1).
// It is a parse-time error, so it has to be reached through eval to be
// observable -- writing it inline would fail to compile this whole file.
var dupThrew = false;
try {
    eval("function dup(a, a) { return a; }");
} catch (e) {
    dupThrew = (e instanceof SyntaxError);
}
assert(dupThrew, "duplicate parameter name is a SyntaxError");

// Deleting a missing property is fine even in strict mode; what strict mode
// forbids is deleting an unqualified identifier, which is a parse-time error.
var frozen = {};
assert(delete frozen.missing === true, "delete of missing prop returns true");

var delIdentThrew = false;
try {
    eval("var bound = 1; delete bound;");
} catch (e) {
    delIdentThrew = (e instanceof SyntaxError);
}
assert(delIdentThrew, "delete of an unqualified identifier is a SyntaxError");

// this in a free function is undefined in strict mode
function getThis() { return this; }
assert(getThis() === undefined, "free-function this === undefined");

// arguments object is not aliased to parameters (no two-way binding)
function argsAlias(x) {
    arguments[0] = 99;
    return x;
}
assert(argsAlias(5) === 5, "arguments and params not aliased (strict)");

print("engine/strict_mode: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");