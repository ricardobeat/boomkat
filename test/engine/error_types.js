// Error types and Error properties
// Tests Error, TypeError, RangeError, URIError, EvalError, SyntaxError.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic Error
var e = new Error("test error");
assert(e.message === "test error", "Error message");
assert(e.name === "Error", "Error name");
assert(typeof e.stack === "string" || e.stack === undefined, "Error stack exists");

// TypeError
var caught = false;
try {
    null.f();
} catch (e) {
    caught = true;
    assert(e instanceof TypeError, "null access is TypeError");
}
assert(caught, "null.f() throws");

// RangeError
caught = false;
try {
    var a = new Array(-1);
} catch (e) {
    caught = true;
    assert(e instanceof RangeError, "negative array length is RangeError");
}

// EvalError (in strict mode, indirect eval)
// In sloppy mode, indirect eval works; we test the type exists
assert(typeof EvalError === "function", "EvalError constructor exists");
var ee = new EvalError("eval problem");
assert(ee.message === "eval problem", "EvalError message");
assert(ee instanceof Error, "EvalError instanceof Error");

// SyntaxError
caught = false;
try {
    eval("function }");
} catch (e) {
    caught = true;
    assert(e instanceof SyntaxError, "bad syntax is SyntaxError");
}
assert(caught, "eval bad syntax throws");

// Custom error hierarchy
function AppError(code, message) {
    this.code = code;
    this.message = message;
    this.name = "AppError";
}
AppError.prototype = new Error();
AppError.prototype.constructor = AppError;

function NotFoundError(resource) {
    AppError.call(this, 404, "Not found: " + resource);
    this.name = "NotFoundError";
    this.resource = resource;
}
NotFoundError.prototype = new AppError();
NotFoundError.prototype.constructor = NotFoundError;

var nfe = new NotFoundError("user/123");
assert(nfe instanceof NotFoundError, "instanceof NotFoundError");
assert(nfe instanceof AppError, "instanceof AppError");
assert(nfe instanceof Error, "instanceof Error");
assert(nfe.code === 404, "custom error code");
assert(nfe.resource === "user/123", "custom error resource");
assert(nfe.name === "NotFoundError", "custom error name");

// Try to catch custom error type
caught = false;
try {
    throw nfe;
} catch (e) {
    caught = true;
    assert(e instanceof NotFoundError, "caught NotFoundError");
    assert(e.code === 404, "caught error has code");
}
assert(caught, "custom error caught");

// Error in finally block replaces thrown error
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

// Multiple catch patterns (simulate with instanceof)
function classifyError(e) {
    if (e instanceof TypeError) return "type";
    if (e instanceof RangeError) return "range";
    if (e instanceof SyntaxError) return "syntax";
    return "unknown";
}
assert(classifyError(new TypeError()) === "type", "classify TypeError");
assert(classifyError(new RangeError()) === "range", "classify RangeError");
assert(classifyError(new SyntaxError()) === "syntax", "classify SyntaxError");
assert(classifyError(new Error()) === "unknown", "classify unknown");

print("engine/error_types: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
