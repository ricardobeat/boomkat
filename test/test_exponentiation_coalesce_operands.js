"use strict";
// Two operand restrictions the Pratt parser's precedence table cannot express
// on its own, because in both cases the spec uses a distinct production rather
// than another precedence level.
//
// 1. ExponentiationExpression (ES2024 §13.6):
//        UnaryExpression
//        UpdateExpression ** ExponentiationExpression
//    The LEFT operand is an UpdateExpression, so `-a ** b` is a SyntaxError:
//    the grammar deliberately refuses to guess between `(-a) ** b` and
//    `-(a ** b)`. The RIGHT operand is a full ExponentiationExpression, so
//    `a ** -b` is fine, and `++a ** b` / `a++ ** b` are UpdateExpressions and
//    stay legal.
//
// 2. CoalesceExpression (ES2021 §13.13):
//        CoalesceExpressionHead ?? BitwiseORExpression
//        ShortCircuitExpression : LogicalORExpression | CoalesceExpression
//    `??` cannot be mixed with an unparenthesized `&&` / `||` in EITHER order.
//    Note the right operand is a BitwiseORExpression, so `a ?? b | c` is a
//    legal `a ?? (b | c)`.
//
// Both were accepted before because `**` was just another precedence level and
// `??` sat directly below `||`.
//
// Runs unmodified under node (`node test/test_exponentiation_coalesce_operands.js`)
// with the same counts. "use strict" is required for parity because a direct
// eval inherits the caller's strictness.

if (typeof print === "undefined") {
    var print = function (s) { console.log(s); };
}

var pass = 0;
var fail = 0;
function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL: " + msg);
    }
}

function syntaxError(source) {
    try {
        eval(source);
        return false;
    } catch (e) {
        return e instanceof SyntaxError;
    }
}

function rejects(src) { assert(syntaxError(src), "must reject " + src); }
function accepts(src) { assert(!syntaxError(src), "must accept " + src); }

// --- every unary operator is illegal on the left of `**` ---
var unaries = ["-", "+", "!", "~", "typeof ", "void ", "delete "];
for (var i = 0; i < unaries.length; i++) {
    rejects(unaries[i] + "a ** 2");
    // Still illegal when the `**` is nested deeper on the right.
    rejects(unaries[i] + "a ** 2 ** 3");
}

// --- parenthesising either side resolves the ambiguity ---
accepts("(-a) ** 2");
accepts("-(a ** 2)");
accepts("(typeof a) ** 2");
accepts("(void 0) ** 2");
// The RIGHT operand is an ExponentiationExpression, which derives UnaryExpression.
accepts("a ** -2");
accepts("a ** typeof b");
accepts("a ** !b");
// UpdateExpressions are exactly what the production admits.
accepts("++a ** 2");
accepts("--a ** 2");
accepts("a++ ** 2");
accepts("a-- ** 2");
// A `**` that is not the first operator has an operator result on its left.
accepts("1 - 2 ** 2");
accepts("1 + 2 ** 2");
accepts("a * b ** c");
// Plain uses must not regress.
accepts("a ** b");
accepts("a ** b ** c");
accepts("-a");
accepts("typeof a");
accepts("-a * b");
accepts("x = -3");

// --- `??` cannot be mixed with `&&` / `||` in either order ---
rejects("a && b ?? c");
rejects("a || b ?? c");
rejects("a ?? b && c");
rejects("a ?? b || c");
rejects("a ?? b || c ?? d");
rejects("a && b || c ?? d");

// --- parentheses make every mix legal ---
accepts("(a && b) ?? c");
accepts("(a || b) ?? c");
accepts("a ?? (b && c)");
accepts("a ?? (b || c)");
accepts("(a ?? b) || c");
accepts("(a ?? b) && c");
// Same operator chained is fine; so is any operand below `&&`/`||`.
accepts("a ?? b");
accepts("a ?? b ?? c");
accepts("a || b || c");
accepts("a && b && c");
accepts("a || b && c");
accepts("a && b || c");
accepts("a ?? b | c");
accepts("a ?? b & c");
accepts("a ?? b + c");
accepts("a ?? b === c");
accepts("a ?? b ? c : d");
accepts("x = a ?? b");

// --- the accepted forms must still EVALUATE correctly ---
assert((null ?? 5) === 5, "?? takes the right operand for null");
assert((0 ?? 5) === 0, "?? keeps a falsy-but-defined left operand");
assert((undefined ?? "u") === "u", "?? takes the right operand for undefined");
assert((null ?? (1 || 2)) === 1, "parenthesised || as a ?? right operand");
assert(((null || 0) ?? 9) === 0, "parenthesised || as a ?? left operand");
assert((null ?? 1 ?? 2) === 1, "chained ??");
// The right operand is a BitwiseORExpression, so `|` binds tighter than `??`.
assert((null ?? 1 | 2) === 3, "?? right operand extends through |");

assert(2 ** 3 ** 2 === 512, "** is right-associative");
assert((-3) ** 2 === 9, "parenthesised negative base");
assert(3 ** -2 === 1 / 9, "negative exponent");
assert(1 - 2 ** 2 === -3, "** binds tighter than -");
assert(-(3 ** 2) === -9, "explicitly parenthesised -(a ** b)");
var upd = 2;
assert(++upd ** 2 === 9, "prefix update as the ** base");
var upd2 = 3;
assert(upd2++ ** 2 === 9, "postfix update as the ** base");

print("exponentiation-coalesce-operands: " + pass + " passed, " + fail + " failed");
if (fail > 0) { print("SOME TESTS FAILED"); throw new Error("FAIL"); }
