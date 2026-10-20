// ES2024 §13.3.6.1 step 6: a call is a direct eval only when the value the
// call expression evaluated is %eval% itself. A bound function, .call or
// .apply that forwards to eval from an `eval(...)` site runs on the caller's
// frame with its pc still on that site, and must still evaluate in the global
// scope. Tail position (`return eval()`) compiles to a TAILCALL opcode and is
// checked alongside an ordinary CALL.
var passed = 0, failed = 0;
function eq(actual, expected, what) {
    if (actual === expected) { passed++; return; }
    failed++;
    print("FAIL: " + what + " -> got " + String(actual) + ", want " + String(expected));
}

var g = this, E = globalThis.eval, L = eval;

function boundTail() { var g = "L"; var eval = E.bind(undefined, "typeof g"); return eval(); }
function boundCall() { var g = "L"; var eval = E.bind(undefined, "typeof g"); var r = eval(); return r; }
function boundLight() { var g = "L"; var eval = L.bind(undefined, "typeof g"); return eval(); }
function viaCall() { var g = "L"; var eval = Function.prototype.call.bind(E, null, "typeof g"); return eval(); }
function viaApply() { var g = "L"; var eval = Function.prototype.apply.bind(E, null, ["typeof g"]); return eval(); }
function boundThis() { var eval = E.bind(undefined, "this === g"); return eval(); }
function direct() { var g = "L"; return eval("typeof g"); }
function directAfterBound() {
    var g = "L";
    var b = E.bind(undefined, "typeof g");
    b();
    return eval("typeof g");
}

eq(boundTail(), "object", "bound eval in tail position");
eq(boundCall(), "object", "bound eval in a plain call");
eq(boundLight(), "object", "bound unmaterialized eval");
eq(viaCall(), "object", "eval forwarded through .call");
eq(viaApply(), "object", "eval forwarded through .apply");
eq(boundThis(), true, "bound eval sees the global this");
eq(direct(), "string", "direct eval sees the local scope");
eq(directAfterBound(), "string", "direct eval after a bound eval call");

print(failed === 0
    ? "PASS (" + passed + " assertions)"
    : "FAILED " + failed + " of " + (passed + failed));
