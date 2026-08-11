// A regexp literal may start the unbraced body of if / while / for.
//
// The `/` after a control clause's closing `)` begins a regexp, not a
// division. Lexer.prev_was_operand (src/lexer.c3) treats RPAREN as
// operand-ending, which is right for `(a + b) / 2` but wrong here, so these
// statements were rejected at parse time with
// "SyntaxError: unexpected token in expression".
//
// The lexer already carries the analogous hint for the `}` case
// (force_regex_after_brace), so the fix follows that pattern for the
// statement parsers.
//
// Minified bundles hit this constantly, because they drop the braces around
// single-statement bodies; it is what broke marked.js. See
// plans/070-real-world-battle-testing.md.
//
// NOTE: these are parse-time failures, so this file must stay separate — a
// single unparseable statement takes the whole file down with it and would
// mask every other test in the same file.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// The three statement forms, as bare statements: reaching the next line at
// all means they parsed.
if (1)/a/.test("a");
while (0)/a/.test("a");
for (; 0;)/a/.test("a");
assertEq(true, true, "bare if/while/for with a regexp body parse");

// The body must actually run, and the regexp must be a regexp.
(function () {
    var hits = 0;
    for (var i = 0; i < 3; i++)/\d/.test(String(i)) && hits++;
    assertEq(hits, 3, "regexp body of an unbraced for runs each iteration");
}());

(function () {
    var ran = false;
    if (1)/x/.test("x") && (ran = true);
    assertEq(ran, true, "regexp body of an unbraced if runs");
}());

(function () {
    var n = 0;
    while (n < 2)/y/.test("y") ? n++ : n++;
    assertEq(n, 2, "regexp body of an unbraced while runs to completion");
}());

// The marked.js shape: a regexp test on an indexed property, in a ternary.
(function () {
    var t = { align: ["  -: ", " :- "] };
    var out = [];
    for (var s = 0; s < t.align.length; s++)/^ *-+: *$/.test(t.align[s]) ? out.push("right") : out.push("other");
    assertEq(out.join(","), "right,other", "marked.js alignment-parsing shape works");
}());

// `if (...) return /re/` — a regexp as the operand of a returned expression.
assertEq((function () { if (1) return /x/.source; }()), "x",
    "regexp literal after if(...) inside a function body");

// else branches take the same path.
(function () {
    var which = "";
    if (0)/a/.test("a"), which = "then"; else/b/.test("b"), which = "else";
    assertEq(which, "else", "regexp body after else parses and runs");
}());

// Division after a *parenthesised expression* must keep lexing as division —
// the fix must not over-correct.
assertEq((4 + 2) / 2, 3, "division after a parenthesised expression still divides");
assertEq((function () { return 8; }()) / 4, 2, "division after a call still divides");
(function () {
    var a = 10, b = 5;
    assertEq((a) / (b), 2, "division between parenthesised operands still divides");
}());

// Forms that already worked must keep working.
(function () {
    var ok = 0;
    do /a/.test("a") && ok++; while (0);
    assertEq(ok, 1, "regexp body of do-while still works");
}());
assertEq(/c/.test("c"), true, "regexp after a block close still works");
switch (1) { case 1: assertEq(/d/.test("d"), true, "regexp after case: still works"); }

if (failures === 0) {
    print("PASS: regexp literal after a control clause");
} else {
    print("FAILURES: " + failures);
}
