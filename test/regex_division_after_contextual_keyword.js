// A `/` after a contextual keyword: division or the start of a RegExp?
//
// The lexer decides from the previous token, but await/yield/let/static lex
// as their own token types rather than IDENTIFIER, so they were never treated
// as ending an operand and `/` always began a regexp. `o.await / r / g` then
// failed to parse.
//
// `let` and `static` never begin a unary expression, so they always end an
// operand. `await` and `yield` depend on the [Await]/[Yield] grammar
// parameters, which only the parser knows, so it syncs them to the lexer.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var r = 2, g = 2;

// --- as property names, all four are ordinary IdentifierNames: division ---
var o = { await: 8, yield: 8, let: 8, static: 8 };
check("o.await / r / g",  o.await / r / g,  2);
check("o.yield / r / g",  o.yield / r / g,  2);
check("o.let / r / g",    o.let / r / g,    2);
check("o.static / r / g", o.static / r / g, 2);

// --- `await` as a binding where [Await] is unset: division ---
function awaitIdent() { var await = 8, r = 2, g = 2; return await / r / g; }
check("await as identifier", awaitIdent(), 2);

// --- `await` where [Await] IS set: the operator, so `/` starts a regexp ---
var asyncResults = [];
async function awaitRegex() { return await /ab/; }
async function awaitDivision() { var q = 4, d = 2; return await q / d; }

// --- `yield` where [Yield] is set: the operator, so `/` starts a regexp ---
function* yieldRegex() { yield /ab/gi; }
check("yield /ab/gi is a regexp", yieldRegex().next().value.flags, "gi");
check("yield regexp source", yieldRegex().next().value.source, "ab");

function* yieldDivision() { var q = 4, d = 2; yield q / d / 1; }
check("yield with division operand", yieldDivision().next().value, 2);

// A regexp is still a regexp in ordinary statement and expression positions.
let lx = /ab/;
check("let x = /ab/", lx.source, "ab");
class C { static m() { return /ab/.source; } }
check("regexp in a static method", C.m(), "ab");
check("regexp after a block", (function () { {} return /ab/.source; })(), "ab");

// Division still works after the operands that always ended one.
check("plain identifier division", (function () { var a = 8; return a / r / g; })(), 2);
check("call-result division", (function () { function f() { return 8; } return f() / r / g; })(), 2);
check("index-result division", [8][0] / r / g, 2);

Promise.all([awaitRegex(), awaitDivision()]).then(function (vals) {
    check("await /ab/ is a regexp", vals[0].source, "ab");
    check("await with division", vals[1], 2);
    if (failures === 0) { print("regex_division_after_contextual_keyword: all checks passed"); }
});
