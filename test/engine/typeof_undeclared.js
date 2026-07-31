// typeof undeclared variables
// Tests that typeof does not throw ReferenceError for undeclared variables.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// typeof undeclared variable returns "undefined" (no ReferenceError)
assert(typeof undeclaredVariable === "undefined", "typeof undeclared variable is 'undefined'");
assert(typeof thisDoesNotExist === "undefined", "typeof another undeclared is 'undefined'");
assert(typeof __nonexistent_symbol_xyz__ === "undefined", "typeof random undeclared is 'undefined'");

// typeof declared-but-undefined variable
var declaredButUndefined;
assert(typeof declaredButUndefined === "undefined", "typeof declared-but-undefined is 'undefined'");

var explicitlyUndefined = undefined;
assert(typeof explicitlyUndefined === "undefined", "typeof explicitly undefined var is 'undefined'");

// typeof null (the famous JS quirk)
assert(typeof null === "object", "typeof null is 'object'");

// typeof function
assert(typeof function(){} === "function", "typeof anonymous function is 'function'");

function namedFunc() {}
assert(typeof namedFunc === "function", "typeof named function is 'function'");

// typeof arrow function (if supported)
// assert(typeof (() => {}) === "function", "typeof arrow function is 'function'");

// Combined: undeclared + function (no crash)
function foo() {}
assert(typeof foo === "function", "function still works after typeof undeclared");

// typeof undeclared inside a function scope
function testUndeclaredInScope() {
    return typeof localUndeclared;
}
assert(testUndeclaredInScope() === "undefined", "typeof local undeclared inside function is 'undefined'");

// Verify that accessing undeclared DOES throw (typeof is the only safe operation)
var threwRefError = false;
try {
    var x = undeclaredReference;
} catch (e) {
    threwRefError = true;
}
assert(threwRefError, "accessing undeclared variable throws ReferenceError");

// typeof on result of expression that uses undeclared (should throw before typeof)
var threwRefError2 = false;
try {
    var y = typeof (undeclaredRef + 1);
} catch (e) {
    threwRefError2 = true;
}
assert(threwRefError2, "typeof wrapping an expression with undeclared throws");

print("engine/typeof_undeclared: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
