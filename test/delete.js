// Test delete operator - flat structure, no ++
var pass = 0, fail = 0;

// 1. Delete own property
var obj = { a: 1, b: 2, c: 3 };
if (delete obj.a) { pass = pass + 1; } else { print("FAIL: delete obj.a"); fail = fail + 1; }
if (obj.a === undefined) { pass = pass + 1; } else { print("FAIL: obj.a should be undefined after delete"); fail = fail + 1; }
if (obj.b === 2) { pass = pass + 1; } else { print("FAIL: obj.b should remain 2"); fail = fail + 1; }

// 2. Delete non-existent property returns true
if (delete obj.nonexistent) { pass = pass + 1; } else { print("FAIL: delete obj.nonexistent should be true"); fail = fail + 1; }

// 3. Delete on a non-reference returns true without evaluating anything.
// `delete 42` / `delete "hello"` are not references, so the result is true
// (ES2015 §12.5.3.2 step 3). But `delete null.a` IS a property reference:
// its base is evaluated and ToObject(null) throws a TypeError, in strict and
// sloppy alike. Verified against node.
try {
    delete null.a;
    print("FAIL: delete null.a should throw TypeError"); fail = fail + 1;
} catch (e) {
    if (e instanceof TypeError) { pass = pass + 1; }
    else { print("FAIL: delete null.a threw " + e.constructor.name); fail = fail + 1; }
}
try {
    delete undefined.a;
    print("FAIL: delete undefined.a should throw TypeError"); fail = fail + 1;
} catch (e) {
    if (e instanceof TypeError) { pass = pass + 1; }
    else { print("FAIL: delete undefined.a threw " + e.constructor.name); fail = fail + 1; }
}
if (delete 42) { pass = pass + 1; } else { print("FAIL: delete 42 should be true"); fail = fail + 1; }
if (delete "hello") { pass = pass + 1; } else { print("FAIL: delete 'hello' should be true"); fail = fail + 1; }

// 4. Delete with bracket notation
var obj4 = { "key with spaces": 10 };
if (delete obj4["key with spaces"]) { pass = pass + 1; } else { print("FAIL: delete obj4['key with spaces']"); fail = fail + 1; }
if (obj4["key with spaces"] === undefined) { pass = pass + 1; } else { print("FAIL: key should be undefined after delete"); fail = fail + 1; }

// 5. Delete array element
var arr = [10, 20, 30, 40];
if (delete arr[1]) { pass = pass + 1; } else { print("FAIL: delete arr[1]"); fail = fail + 1; }
if (arr[1] === undefined) { pass = pass + 1; } else { print("FAIL: arr[1] should be undefined after delete"); fail = fail + 1; }
if (arr.length === 4) { pass = pass + 1; } else { print("FAIL: arr.length should still be 4 after delete"); fail = fail + 1; }
if (arr[0] === 10 && arr[2] === 30 && arr[3] === 40) { pass = pass + 1; } else { print("FAIL: other array elements should remain"); fail = fail + 1; }

// 6. Nested property delete
var nested = { x: { y: 10, z: 20 } };
if (delete nested.x.y) { pass = pass + 1; } else { print("FAIL: delete nested.x.y"); fail = fail + 1; }
if (nested.x.y === undefined) { pass = pass + 1; } else { print("FAIL: nested.x.y should be undefined"); fail = fail + 1; }
if (nested.x.z === 20) { pass = pass + 1; } else { print("FAIL: nested.x.z should remain 20"); fail = fail + 1; }
if (delete nested.x) { pass = pass + 1; } else { print("FAIL: delete nested.x"); fail = fail + 1; }
if (nested.x === undefined) { pass = pass + 1; } else { print("FAIL: nested.x should be undefined after delete"); fail = fail + 1; }

// 7. SKIPPED: variable delete (`delete myvar`).
// This is sloppy-mode-only behaviour. Deleting an unqualified identifier is
// an early SyntaxError in strict code (ES2015 §12.5.3.1), and this engine
// runs all code as strict, so the statement cannot even be parsed here --
// it has to stay commented out rather than merely skipped at runtime.
// Not an engine bug: matches node's behaviour under "use strict".
//   var myvar = "hello";
//   delete myvar;  // SyntaxError in strict mode

// 8. Delete from prototype chain (own property delete vs inherited)
function Foo() {}
Foo.prototype.prop = 42;
var foo = new Foo();
// delete of inherited property on instance is a delete of own property
// Since foo doesn't have own 'prop', foo.prop resolves via prototype
// delete returns true but nothing was actually deleted from the instance
if (delete foo.prop) { pass = pass + 1; } else { print("FAIL: delete foo.prop should return true"); fail = fail + 1; }
// Inherited prop should still be accessible
if (foo.prop === 42) { pass = pass + 1; } else { print("FAIL: foo.prop should still be 42 via prototype"); fail = fail + 1; }

// Summary
print("delete tests: " + pass + " pass, " + fail + " fail");
if (fail > 0) { print("FAIL"); }
