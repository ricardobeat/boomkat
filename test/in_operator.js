// 'in' operator. TinyDuck: own-property check only. No prototype chain.
var pass = 0, fail = 0;

// 1. Basic property existence
var obj = { a: 1, b: 2, c: 3 };
if ("a" in obj) { pass = pass + 1; } else { print("FAIL: 'a' in obj"); fail = fail + 1; }
if ("b" in obj) { pass = pass + 1; } else { print("FAIL: 'b' in obj"); fail = fail + 1; }
if (!("d" in obj)) { pass = pass + 1; } else { print("FAIL: 'd' not in obj"); fail = fail + 1; }
// toString is NOT a property of obj (no prototype chain)
if (!("toString" in obj)) { pass = pass + 1; } else { print("FAIL: 'toString' should not be in obj (no proto)"); fail = fail + 1; }

// 2. Array indices
var arr = [10, 20, 30];
if ("0" in arr) { pass = pass + 1; } else { print("FAIL: '0' in arr"); fail = fail + 1; }
if ("1" in arr) { pass = pass + 1; } else { print("FAIL: '1' in arr"); fail = fail + 1; }
if ("2" in arr) { pass = pass + 1; } else { print("FAIL: '2' in arr"); fail = fail + 1; }
if (!("3" in arr)) { pass = pass + 1; } else { print("FAIL: '3' not in arr"); fail = fail + 1; }
if ("length" in arr) { pass = pass + 1; } else { print("FAIL: 'length' in arr"); fail = fail + 1; }

// 3. Number indices work too
if (0 in arr) { pass = pass + 1; } else { print("FAIL: 0 in arr (numeric)"); fail = fail + 1; }
if (!(5 in arr)) { pass = pass + 1; } else { print("FAIL: 5 not in arr (numeric)"); fail = fail + 1; }

// 4. TypeError on non-object right side
function expectTypeError(thunk) {
    try { thunk(); return false; } catch (e) { return e instanceof TypeError; }
}
if (expectTypeError(function() { var x = "prop" in null; })) { pass = pass + 1; } else { print("FAIL: 'prop' in null should throw TypeError"); fail = fail + 1; }
if (expectTypeError(function() { var x = "prop" in undefined; })) { pass = pass + 1; } else { print("FAIL: 'prop' in undefined should throw TypeError"); fail = fail + 1; }
if (expectTypeError(function() { var x = "prop" in 42; })) { pass = pass + 1; } else { print("FAIL: 'prop' in number should throw TypeError"); fail = fail + 1; }
if (expectTypeError(function() { var x = "length" in "hello"; })) { pass = pass + 1; } else { print("FAIL: 'prop' in string should throw TypeError"); fail = fail + 1; }
if (expectTypeError(function() { var x = "prop" in true; })) { pass = pass + 1; } else { print("FAIL: 'prop' in boolean should throw TypeError"); fail = fail + 1; }

// 5. String literals as property names
var person = { name: "Alice", age: 30 };
var p = "name";
if (p in person) { pass = pass + 1; } else { print("FAIL: p='name' in person"); fail = fail + 1; }
var q = "age";
if (q in person) { pass = pass + 1; } else { print("FAIL: q='age' in person"); fail = fail + 1; }
var r = "foo";
if (!(r in person)) { pass = pass + 1; } else { print("FAIL: r='foo' not in person"); fail = fail + 1; }

// 6. Empty object — no inherited keys
var empty = {};
if (!("anything" in empty)) { pass = pass + 1; } else { print("FAIL: 'anything' not in empty"); fail = fail + 1; }
if (!("toString" in empty)) { pass = pass + 1; } else { print("FAIL: 'toString' should NOT be in empty (no proto)"); fail = fail + 1; }

// 7. After delete, key is no longer in
var d = { x: 1, y: 2 };
delete d.x;
if (!("x" in d)) { pass = pass + 1; } else { print("FAIL: deleted key still in"); fail = fail + 1; }
if ("y" in d) { pass = pass + 1; } else { print("FAIL: 'y' not in d"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);
