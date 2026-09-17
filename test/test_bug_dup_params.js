// Duplicate parameter names via the Function constructor: a SyntaxError in
// strict-mode bodies (the default pre-plans/083), while sloppy bodies — the
// Function constructor's default — accept them with last-one-wins semantics
// (Annex B.3.1). Also covers the direct-source strict form.

function runTest() {
    try {
        var fn = new Function('"use strict";', "a", "a", "return;");
        print("FAIL: strict dup params accepted, got fn =", String(fn));
        return false;
    } catch (e) {
        if (e instanceof SyntaxError) {
            print("PASS: strict SyntaxError thrown:", e.constructor.name);
        } else {
            print("FAIL: expected SyntaxError, got:", e.constructor.name, String(e));
            return false;
        }
    }
    try {
        var sloppy = new Function("a", "a", "return a;");
        var r = sloppy(3, 7);
        if (r !== 7) { print("FAIL: sloppy dup params, got", r); return false; }
        print("PASS: sloppy dup params last-one-wins");
    } catch (e) {
        print("FAIL: sloppy dup params threw:", e.constructor.name, String(e));
        return false;
    }
    return true;
}

if (!runTest()) { if (typeof process !== "undefined" && process.exit) process.exit(1); }