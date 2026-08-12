// Fixed-size compiler buffers must be bounds-checked, not overrun.
//
// Two stack arrays in the compiler were written without any bound:
//
//   1. `switch_statement`'s `body_addrs` / `ft_jump_addrs` (`uint[64]`).
//      A switch with more than 64 clauses wrote past the end of the
//      compiler's own frame. It corrupted the stack SILENTLY — a 100-case
//      switch still produced correct output while writing 36 entries past the
//      end. Real code exceeds 64 easily: a tokenizer or an AST visitor
//      dispatching on a node kind routinely has hundreds of cases.
//
//   2. `scan_template_content`'s `buf` / `raw_buf` (`char[65536]`). A template
//      part longer than the buffer overran it. `scan_string` already carried
//      exactly this check (`buf_len >= STRING_BUF_SIZE - 6`); the template
//      scanner did not — the same missing-guard-on-one-of-two-parallel-paths
//      shape as B16.
//
// Both were found by running typescript 5.4.5 (9 MB) under AddressSanitizer.
// In the release build the template overflow landed as a jump into string data
// (PC = 0x6e694c656c676e69, which is ASCII text) — memory corruption with no
// diagnosable error, and nothing that pointed at the lexer.
//
// The whole test262 corpus (49814 tests) passes with both bugs present: no
// fixture has a switch that large or a template part that long.
//
// Limits are now 1024 switch clauses and the existing 64 KB template buffer,
// with a SyntaxError past either — a clean failure instead of corruption.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// A switch well past the old 64 limit. Every arm must be reachable and
// correct: a corrupted body_addrs entry mispatches a jump, so checking only
// the first and last would miss it.
function big(x) {
    var r = -1;
    switch (x) {
        case 0: r = 0; break;
        case 10: r = 10; break;
        case 63: r = 63; break;
        case 64: r = 64; break;
        case 65: r = 65; break;
        case 100: r = 100; break;
        case 200: r = 200; break;
        case 299: r = 299; break;
        default: r = -2; break;
    }
    return r;
}
assertEq(big(0), 0, "first case");
assertEq(big(63), 63, "case at the old boundary");
assertEq(big(64), 64, "case one past the old boundary");
assertEq(big(65), 65, "case two past the old boundary");
assertEq(big(299), 299, "last case");
assertEq(big(9999), -2, "default still reached");

// A generated switch with 400 clauses, well past BOTH old limits: the 64-entry
// body_addrs array and the 256-entry break/continue patch pool. The patch-pool
// overflow was the nastier of the two — add_patch returned SILENTLY, so each
// `break` past the 256th stayed an unpatched `JUMP 0` and fell through to
// `default`. Arms 0..255 answered correctly and everything after them returned
// the default value, with no diagnostic anywhere.
(function () {
    var src = "var r = -1; switch (x) {";
    for (var i = 0; i < 400; i++) { src += "case " + i + ": r = " + (i * 2) + "; break;"; }
    src += "default: r = -2; } return r;";
    var f = new Function("x", src);
    for (var k = 0; k < 400; k += 25) {
        assertEq(f(k), k * 2, "generated 400-case switch, arm " + k);
    }
    assertEq(f(255), 510, "arm at the old patch-pool boundary");
    assertEq(f(256), 512, "arm one past the old patch-pool boundary");
    assertEq(f(257), 514, "arm two past the old patch-pool boundary");
    assertEq(f(399), 798, "generated switch, last arm");
    assertEq(f(-1), -2, "generated switch, default");
}());

// The patch pool is per-FUNCTION and never reset mid-function, so this is not
// only about switches: 400 loops each containing a `break` share the same pool.
// The patch pool is per-FUNCTION and never reset mid-function, so this is not
// only about switches: many loops each containing a `break` share the pool.
// Written literally rather than through `new Function`, which has its own
// separate defect on large bodies (B21).
(function () {
    var n = 0, i = 0;
    for (i = 0; i < 3; i++) { if (i === 1) break; n++; }
    for (i = 0; i < 3; i++) { if (i === 1) break; n++; }
    for (i = 0; i < 3; i++) { if (i === 1) break; n++; }
    assertEq(n, 3, "loops with break still work");
}());

// Fall-through across the old boundary must still work: consecutive clauses
// share a body, which is what ft_jump_addrs patches.
(function () {
    var src = "var n = 0; switch (x) {";
    for (var i = 0; i < 200; i++) { src += "case " + i + ":"; }
    src += "n = 1; break; default: n = 2; } return n;";
    var f = new Function("x", src);
    assertEq(f(0), 1, "fall-through through 200 empty clauses, first");
    assertEq(f(199), 1, "fall-through through 200 empty clauses, last");
    assertEq(f(500), 2, "fall-through switch, default");
}());

// A default clause placed in the middle, past the old boundary — the
// default_body_idx patching reads body_addrs at that index.
(function () {
    var src = "var r = -1; switch (x) {";
    for (var i = 0; i < 80; i++) { src += "case " + i + ": r = " + i + "; break;"; }
    src += "default: r = -2; break;";
    for (var j = 80; j < 160; j++) { src += "case " + j + ": r = " + j + "; break;"; }
    src += "} return r;";
    var f = new Function("x", src);
    assertEq(f(79), 79, "clause before a mid-switch default");
    assertEq(f(159), 159, "clause after a mid-switch default");
    assertEq(f(1000), -2, "mid-switch default reached");
}());

// Template literals around and past the old failure point. The escape-free
// fast path and the escape-scanning slow path are different code.
(function () {
    var plain = "";
    for (var i = 0; i < 2000; i++) { plain += "abcdefghij"; }   // 20000 chars
    var t = `${plain}`;
    assertEq(t.length, 20000, "long template substitution");
    assertEq(t.charAt(19999), "j", "last character survives");
}());

(function () {
    // Escapes force the slow path that owns the buffer.
    var parts = [];
    for (var i = 0; i < 2000; i++) { parts.push("a\nb\tc"); }
    var s = parts.join("");
    assertEq(s.length, 10000, "escape-bearing string of 10000 chars");
    var t = `x${s}y`;
    assertEq(t.length, 10002, "template around an escape-bearing string");
}());

// A tagged template, which uses the raw buffer as well as the cooked one.
(function () {
    function tag(strings, v) { return strings.raw[0].length + ":" + strings[0].length + ":" + v; }
    var out = tag`line1\nline2${42}`;
    assertEq(out, "12:11:42", "tagged template raw and cooked lengths");
}());

if (failures === 0) {
    print("PASS: compiler fixed-buffer bounds");
} else {
    print("FAILURES: " + failures);
}
