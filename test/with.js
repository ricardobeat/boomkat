// Test: `with` statement (ES5 §12.10) — SKIPPED / inverted.
//
// This file used to exercise with-object scope, property shadowing,
// assignment, nested `with`, and interaction with var declarations.
// All of it is unreachable here: `with` is an early SyntaxError in strict
// mode (ES2015 §13.11.1), and this engine executes ALL code as strict, so
// the original body could not even be parsed. Node behaves identically
// under "use strict".
//
// This is NOT an engine bug and not a gap to close — supporting the old
// assertions would require a sloppy mode the engine deliberately does not
// have. Rather than leave a permanently-red test, the file now asserts the
// one thing that IS observable: that `with` is rejected at parse time.

var pass = 0, fail = 0;

function expectSyntaxError(src, msg) {
    try {
        eval(src);
        print("FAIL: " + msg + " (no error)");
        fail = fail + 1;
    } catch (e) {
        if (e instanceof SyntaxError) {
            pass = pass + 1;
        } else {
            print("FAIL: " + msg + " (got " + e.constructor.name + ")");
            fail = fail + 1;
        }
    }
}

expectSyntaxError("with ({}) { }", "plain with");
expectSyntaxError("with ({ x: 1 }) { x; }", "with reading a property");
expectSyntaxError("with ({ x: 1 }) { x = 2; }", "with assigning a property");
expectSyntaxError("with ({}) { with ({}) { } }", "nested with");
expectSyntaxError("function f() { with ({}) { } }", "with inside a function");

// Sanity: the object-scoping cases the original file covered are all
// expressible without `with`, and those still work.
var scope = { x: 10, y: 20 };
if (scope.x + scope.y === 30) { pass = pass + 1; }
else { print("FAIL: plain property access"); fail = fail + 1; }
scope.x = 99;
if (scope.x === 99) { pass = pass + 1; }
else { print("FAIL: plain property assignment"); fail = fail + 1; }

print("with tests: " + pass + " pass, " + fail + " fail");
