// Early errors for invalid AssignmentTargetType (ES2024 §13.15.1).
//
// An operator's result is a value, never a Reference, so it can never be the
// target of an assignment / compound assignment / update expression. Wrapping
// it in parentheses does not change that: CoverParenthesizedExpression forwards
// the inner expression's AssignmentTargetType unchanged.
//
// The engine tracks "the expression just parsed was a Reference" with the
// last_was_getvar / last_was_member / last_was_local_var markers. The bug this
// covers was those markers surviving an operator and describing the operator's
// last OPERAND instead of its result, so `x + y = 1` was silently accepted and
// compiled to an assignment to `y`.

function syntaxError(source) {
    try {
        eval(source);
        return false;
    } catch (e) {
        return e instanceof SyntaxError;
    }
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

// --- Binary operators: every precedence level, parenthesized and bare ------
var binaryOps = [
    "===", "!==", "==", "!=",
    "+", "-", "*", "/", "%", "**",
    "&", "|", "^", "<<", ">>", ">>>",
    "<", ">", "<=", ">=",
    "instanceof", "in",
    "&&", "||", "??"
];
for (var i = 0; i < binaryOps.length; i++) {
    var op = binaryOps[i];
    assert(syntaxError("var a, b; (a " + op + " b) = 1;"),
           "parenthesized `a " + op + " b` as assignment target");
    assert(syntaxError("var a, b; a " + op + " b = 1;"),
           "bare `a " + op + " b` as assignment target");
}

// Literal operands, not just identifiers — the result is still a value.
assert(syntaxError("1 + 2 = 1;"), "1 + 2 = 1");
assert(syntaxError("true + false = 1;"), "true + false = 1");

// --- Unary operators -------------------------------------------------------
assert(syntaxError("var a; -a = 1;"), "-a = 1");
assert(syntaxError("var a; +a = 1;"), "+a = 1");
assert(syntaxError("var a; !a = 1;"), "!a = 1");
assert(syntaxError("var a; ~a = 1;"), "~a = 1");

// --- Conditional and comma expressions ------------------------------------
assert(syntaxError("var a, b, c; (a ? b : c) = 1;"), "(a ? b : c) = 1");
assert(syntaxError("var a, b; (a, b) = 1;"), "(a, b) = 1");

// --- Compound assignment and update forms use the same target check --------
assert(syntaxError("var a, b; (a + b) += 1;"), "(a + b) += 1");
assert(syntaxError("var a, b; (a + b) -= 1;"), "(a + b) -= 1");
assert(syntaxError("var a, b; (a + b)++;"), "(a + b)++ postfix");
assert(syntaxError("var a, b; ++(a + b);"), "++(a + b) prefix");
assert(syntaxError("var a, b; (a ? b : a) = 1;"), "ternary compound target");

// --- Valid targets must STILL be accepted (over-rejection guard) -----------
// Every one of these is accepted by V8; a regression here is worse than the
// bug above, so they are asserted explicitly rather than left implicit.
assert(!syntaxError("var a; a = 1;"), "bare identifier target");
assert(!syntaxError("var a; (a) = 1;"), "parenthesized identifier target");
assert(!syntaxError("var a; ((a)) = 1;"), "doubly parenthesized identifier");
assert(!syntaxError("var o = {}; o.b = 1;"), "member target");
assert(!syntaxError("var o = {}; (o.b) = 1;"), "parenthesized member target");
assert(!syntaxError("var o = {}; o['b'] = 1;"), "computed member target");
assert(!syntaxError("var o = {x:{}}; o.x.y = 1;"), "nested member target");
assert(!syntaxError("var a; a += 1;"), "compound assignment to identifier");
assert(!syntaxError("var o = {b:0}; o.b += 1;"), "compound assignment to member");
assert(!syntaxError("var a = 0; a++;"), "postfix update on identifier");
assert(!syntaxError("var a = 0; ++a;"), "prefix update on identifier");
assert(!syntaxError("var o = {b:0}; o.b++;"), "postfix update on member");
assert(!syntaxError("var a, b; a + b;"), "operator result as a plain value");
assert(!syntaxError("var a, b, c; a ? b : c;"), "ternary as a plain value");
assert(!syntaxError("var a, b; (a, b);"), "comma expression as a plain value");
assert(!syntaxError("var a, b; var q = a + b;"), "operator result as initializer");
assert(!syntaxError("var a, b = {}; for (a in b) {}"), "for-in identifier head");
assert(!syntaxError("var o = {}, b = {}; for (o.p in b) {}"), "for-in member head");
assert(!syntaxError("var a, b; a = b = 1;"), "chained assignment");
assert(!syntaxError("var a, b; a = (b, 1);"), "comma expression as RHS");
assert(!syntaxError("var a, b; a = -b;"), "unary result as RHS");

// --- The operators must still COMPUTE correctly ----------------------------
// Clearing the reference markers must not disturb code generation.
var x = 2, y = 3;
assert(x + y === 5, "addition still evaluates");
assert((x < y ? x : y) === 2, "ternary still evaluates");
assert((x, y) === 3, "comma still yields its last operand");
assert(-x === -2, "unary minus still evaluates");
assert((x === 2) === true, "strict equality still evaluates");
var w = 2;
assert((w = 2) * (w = 3) === 6, "left operand value preserved across RHS");

print('assignment-target-type: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
