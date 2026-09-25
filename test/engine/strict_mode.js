// Strict-mode semantics.
// Scripts default to sloppy (ES2024 §16.2.1.1), so each strict-only assertion
// runs inside its own strict-mode function body (the directive is a no-op in
// modern strict code).

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// A "use strict" directive must still parse and run as a no-op.
(function () { "use strict"; return 1; })();
assert((function () { "use strict"; return 1; })() === 1, "'use strict' directive is accepted");

// Strict-mode rules: assign to undeclared var must throw
var undeclThrew = false;
try {
    (function () { "use strict"; undeclaredVariable = 42; })();
} catch (e) {
    undeclThrew = true;
}
assert(undeclThrew, "should have thrown on assignment to undeclared var");

// Duplicate parameter names are a SyntaxError in strict code (ES5.1 s13.1).
// It is a parse-time error, so it has to be reached through eval to be
// observable -- writing it inline would fail to compile this whole file.
var dupThrew = false;
try {
    eval('"use strict"; function dup(a, a) { return a; }');
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
    eval('"use strict"; var bound = 1; delete bound;');
} catch (e) {
    delIdentThrew = (e instanceof SyntaxError);
}
assert(delIdentThrew, "delete of an unqualified identifier is a SyntaxError");

// this in a free function is undefined in strict mode
var thisIsUndef;
(function () { "use strict"; thisIsUndef = (function getThis() { return this; })(); })();
assert(thisIsUndef === undefined, "free-function this === undefined");

// arguments object is not aliased to parameters (no two-way binding)
var argsRet;
(function () {
    "use strict";
    function argsAlias(x) {
        arguments[0] = 99;
        return x;
    }
    argsRet = argsAlias(5);
})();
assert(argsRet === 5, "arguments and params not aliased (strict)");

print("engine/strict_mode: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");