// Exception handling
// Tests try/catch/finally, throw, custom Error types.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic try/catch
var result = "none";
try {
    throw "error string";
} catch (e) {
    result = e;
}
assert(result === "error string", "catch string throw");

// try/catch/finally
var log = [];
try {
    log.push("try");
    throw new Error("oops");
} catch (e) {
    log.push("catch: " + e.message);
} finally {
    log.push("finally");
}
assert(log.join(",") === "try,catch: oops,finally", "try/catch/finally order");

// Finally runs even on normal return
function withFinally() {
    try { return 42; } finally { log.push("returned"); }
}
var v = withFinally();
assert(v === 42, "finally doesn't override return");
assert(log[log.length - 1] === "returned", "finally runs on normal return");

// Finally side-effect: variable modified in finally persists
var finallyExecuted = false;
function finallySideEffect() {
    try {
        return 42;
    } finally {
        finallyExecuted = true;
    }
}
assert(finallySideEffect() === 42, "return value preserved when finally sets a variable");
assert(finallyExecuted, "finally block runs and modifies outer variable after return");

// Nested try-finally with return from inner block
var finallyOrder = [];
function nestedTryFinally() {
    finallyOrder = [];
    try {
        finallyOrder.push("outer try");
        try {
            finallyOrder.push("inner try");
            return "inner-value";
        } finally {
            finallyOrder.push("inner finally");
        }
    } finally {
        finallyOrder.push("outer finally");
    }
}
var nestedResult = nestedTryFinally();
assert(nestedResult === "inner-value", "nested try-finally returns inner value");
assert(finallyOrder[0] === "outer try", "nested order: outer try first");
assert(finallyOrder[1] === "inner try", "nested order: then inner try");
assert(finallyOrder[2] === "inner finally", "nested order: inner finally runs before outer finally");
assert(finallyOrder[3] === "outer finally", "nested order: outer finally runs last");

// Deeply nested try-finally with three levels
function deepNestedFinally() {
    var v = 0;
    try {
        try {
            try {
                return 99;
            } finally {
                v += 10;
            }
        } finally {
            v += 100;
        }
    } finally {
        v += 1000;
    }
    return -1;
}
assert(deepNestedFinally() === 99, "deeply nested try-finally preserves innermost return");
// All finally blocks run

// Custom error type
function ValueError(msg) {
    this.message = msg;
    this.name = "ValueError";
}
ValueError.prototype = new Error();
ValueError.prototype.constructor = ValueError;

var caught = false;
try {
    throw new ValueError("bad value");
} catch (e) {
    caught = true;
    assert(e instanceof ValueError, "catch custom error type");
    assert(e.message === "bad value", "custom error message");
    assert(e.name === "ValueError", "custom error name");
}
assert(caught, "custom error was caught");

// Nested try/catch
var depth = 0;
try {
    try {
        try {
            throw 3;
        } catch (e) {
            depth = e;
            throw e - 1;
        }
    } catch (e) {
        depth += e;
        throw e - 1;
    }
} catch (e) {
    depth += e;
}
assert(depth === 6, "nested catches accumulate: " + depth);

// Re-throw
var rethrown = false;
try {
    try {
        throw new Error("inner");
    } catch (e) {
        throw e; // re-throw
    }
} catch (e) {
    rethrown = true;
    assert(e.message === "inner", "re-thrown error preserved");
}
assert(rethrown, "re-thrown caught");

// Catch with no error (normal flow)
var normalFlow = false;
try {
    normalFlow = true;
} catch (e) {
    fail++;
}
assert(normalFlow, "try without throw runs normally");

print("engine/try_catch: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
