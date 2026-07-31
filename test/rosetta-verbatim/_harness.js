// Shared assertion harness for the verbatim Rosetta suite.
//
// The samples under test are byte-identical copies of rosettacode.org code, so
// they carry no assertions of their own; each <name>.check.js imports the
// sample and states the expectations here.
var pass = 0, fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print("FAIL: " + msg); }
}

function assertEq(actual, expected, msg) {
    assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// The engine resolves an unexported top-level binding to `undefined` rather
// than failing to link, so a renamed or missing sample function would silently
// assert against `undefined` and pass. Every check file calls this first so a
// broken import is a loud failure instead.
function assertImported(fn, name) {
    assert(typeof fn === "function", "sample did not export " + name + " (got " + typeof fn + ")");
}

function report(name) {
    print("rosetta-verbatim/" + name + ": " + pass + " passed, " + fail + " failed");
    if (fail > 0) throw new Error("FAIL");
}

export { assert, assertEq, assertImported, report };
