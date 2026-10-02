/// Regression tests for NativeErrors prototype.constructor (B16).
///
/// Per ES6 §19.5.6.x the initial value of XxxError.prototype.constructor is
/// the corresponding intrinsic XxxError object. Direct chained access
/// (`URIError.prototype.constructor`) must work with a lightfunc (URIError
/// itself) as the source of the first hop.

function check(name, actual, expected) {
    var ok = actual === expected;
    if (!ok) {
        print("FAIL: " + name + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
        return false;
    }
    return true;
}

var all_pass = true;

// ── All NativeErrors constructor property ──────────────────────────────────
var errors = ["Error", "TypeError", "RangeError", "ReferenceError",
              "SyntaxError", "EvalError", "URIError", "AggregateError"];
for (var i = 0; i < errors.length; i++) {
    var E = globalThis[errors[i]];
    var c = E.prototype.constructor;
    all_pass &= check(errors[i] + " constructor === E", c, E);
}

// ── Chained access via different patterns ──────────────────────────────────
{
    // `URIError.prototype.constructor` — the original repro.
    var c1 = URIError.prototype.constructor;
    all_pass &= check("URIError.prototype.constructor", c1, URIError);
}
{
    var c2 = TypeError.prototype["constructor"];
    all_pass &= check("TypeError.prototype[constructor]", c2, TypeError);
}
{
    var c3 = RangeError["prototype"].constructor;
    all_pass &= check("RangeError[prototype].constructor", c3, RangeError);
}

// ── Other lightfunc property chains ───────────────────────────────────────
{
    // URIError.length should be 1 (lightfunc arity metadata).
    all_pass &= check("URIError.length", URIError.length, 1);
}
{
    // URIError.name should be "URIError" (lightfunc name metadata).
    all_pass &= check("URIError.name", URIError.name, "URIError");
}
// NOTE: chained access on a lightfunc-returned string (`URIError.name.length`)
// is not covered here.

// ── Constructor property descriptor ────────────────────────────────────────
{
    var desc = Object.getOwnPropertyDescriptor(URIError.prototype, "constructor");
    all_pass &= check("URIError.prototype.constructor desc.value", desc.value, URIError);
    all_pass &= check("URIError.prototype.constructor desc.writable", desc.writable, true);
    all_pass &= check("URIError.prototype.constructor desc.enumerable", desc.enumerable, false);
    all_pass &= check("URIError.prototype.constructor desc.configurable", desc.configurable, true);
}

// ── Lightfunc method call still works after chain ──────────────────────────
{
    // Boolean.prototype is a HObject with various props.
    var bproto = Boolean.prototype;
    all_pass &= check("Boolean.prototype typeof", typeof bproto, "object");
}

if (all_pass) {
    print("PASS: all B16 NativeErrors constructor assertions");
} else {
    print("FAIL: some B16 NativeErrors constructor assertions");
}
