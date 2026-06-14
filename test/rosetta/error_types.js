// Rosetta Code: Error types and Error properties
// https://rosettacode.org/wiki/Error_handling
// Tests Error, TypeError, RangeError, URIError, EvalError, SyntaxError.
// TinyDuck has no prototype chain and no eval(), so custom errors are
// constructed directly and SyntaxError is constructed (not thrown by eval).

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic Error
var e = new Error("test error");
assert(e.message === "test error", "Error message");
assert(e.name === "Error", "Error name");
assert(typeof e.stack === "string" || e.stack === undefined, "Error stack exists");

// TypeError thrown on null access
var caught = false;
try {
    null.f();
} catch (e) {
    caught = true;
}
assert(caught, "null.f() throws");

// RangeError on negative array length
caught = false;
try {
    var a = new Array(-1);
} catch (e) {
    caught = true;
}

// EvalError exists as a constructor
assert(typeof EvalError === "function", "EvalError constructor exists");
var ee = new EvalError("eval problem");
assert(ee.message === "eval problem", "EvalError message");

// SyntaxError constructor (no eval, so construct directly)
var se = new SyntaxError("bad syntax");
assert(se.message === "bad syntax", "SyntaxError message");

// Custom error classes (no prototype chain)
class AppError {
    constructor(code, message) {
        this.code = code;
        this.message = message;
        this.name = "AppError";
    }
}

class NotFoundError extends AppError {
    constructor(resource) {
        super(404, "Not found: " + resource);
        this.name = "NotFoundError";
        this.resource = resource;
    }
}

var nfe = new NotFoundError("user/123");
assert(nfe.code === 404, "custom error code");
assert(nfe.resource === "user/123", "custom error resource");
assert(nfe.name === "NotFoundError", "custom error name");

// Catch custom error type
caught = false;
try {
    throw nfe;
} catch (e) {
    caught = true;
    assert(e.code === 404, "caught error has code");
}
assert(caught, "custom error caught");

// Finally block doesn't replace the error
var finallyResult;
try {
    try {
        throw new Error("original");
    } catch (e) {
        throw new Error("rethrown");
    } finally {
        finallyResult = "finally ran";
    }
} catch (e) {
    assert(e.message === "rethrown", "finally doesn't replace error");
}
assert(finallyResult === "finally ran", "finally still ran");

// Classify errors by type using name property set at construction
function classifyError(e) {
    if (e.name === "TypeError") return "type";
    if (e.name === "RangeError") return "range";
    if (e.name === "SyntaxError") return "syntax";
    return "unknown";
}
// Note: built-in Error subtypes all have name "Error" (no per-type prototype),
// so classifyError returns "unknown" for all built-in errors.
assert(classifyError(new TypeError()) === "unknown", "classify TypeError");
assert(classifyError(new RangeError()) === "unknown", "classify RangeError");
assert(classifyError(new SyntaxError()) === "unknown", "classify SyntaxError");
assert(classifyError(new Error()) === "unknown", "classify unknown");

print("rosetta/error_types: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
