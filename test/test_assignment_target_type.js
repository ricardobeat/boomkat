"use strict";
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
//
// Runs unmodified under node (`node test/test_assignment_target_type.js`) with
// the same counts. The "use strict" directive is required for parity: a direct
// eval inherits the caller's strictness, and the eval/arguments rules below are
// strict-only.

if (typeof print === "undefined") {
    var print = function (s) { console.log(s); };
}

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

// --- `delete` yields a boolean, so its target type is ~invalid~ ------------
// The delete path cleared only the member marker, so the operand's identifier
// markers survived and made the result look assignable.
assert(syntaxError("var o = {}; delete o.b = 1;"), "delete o.b = 1");
assert(syntaxError("var o = {}; (delete o.b) = 1;"), "(delete o.b) = 1");
assert(syntaxError("var o = {}; delete o.b += 1;"), "delete o.b += 1");
assert(syntaxError("var o = {}; delete o['b'] = 1;"), "delete o['b'] = 1");
assert(syntaxError("var a; typeof a = 1;"), "typeof a = 1");
assert(syntaxError("var a; void a = 1;"), "void a = 1");

// --- parentheses PRESERVE AssignmentTargetType, so `(eval) = 1` is still the
// forbidden strict-mode assignment to `eval` (§13.15.1). The saved LHS name was
// being cleared at every `)` to suppress NamedEvaluation — which parentheses
// genuinely do suppress — so one field was doing two jobs and this check was
// silently disabled for any parenthesized target.
assert(syntaxError("(eval) = 1;"), "(eval) = 1");
assert(syntaxError("(arguments) = 1;"), "(arguments) = 1");
assert(syntaxError("((eval)) = 1;"), "((eval)) = 1");
assert(syntaxError("(eval) += 1;"), "(eval) += 1");
assert(syntaxError("(arguments) += 1;"), "(arguments) += 1");
assert(syntaxError("(eval)++;"), "(eval)++");
assert(syntaxError("++(eval);"), "++(eval)");
// The unparenthesized forms, so the two paths cannot diverge again.
assert(syntaxError("eval = 1;"), "eval = 1");
assert(syntaxError("arguments = 1;"), "arguments = 1");
assert(syntaxError("eval++;"), "eval++");

// `eval` / `arguments` are restricted only as assignment TARGETS.
assert(!syntaxError("(eval)('1');"), "(eval)(...) is a call, not a target");
assert(!syntaxError("var readEval = (eval);"), "reading (eval)");
assert(!syntaxError("var o = {}; o.eval = 1;"), "`eval` as a property name");
assert(!syntaxError("var o = { eval: 1 };"), "`eval` as a literal key");

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

// NamedEvaluation (§13.15.2 step 1.c) tests IsIdentifierRef, which a
// CoverParenthesizedExpression never satisfies. Parentheses must keep
// suppressing the inferred name even though they no longer suppress the
// eval/arguments target check above.
var fnAnon;
(fnAnon) = function () {};
assert(fnAnon.name === "", "parenthesized LHS does not name the function");
var fnNamed;
fnNamed = function () {};
assert(fnNamed.name === "fnNamed", "bare identifier LHS still names the function");

// A parenthesized simple target still assigns.
var p = 0;
(p) = 9;
assert(p === 9, "parenthesized simple target still assigns");
var q = 0;
(q) += 5;
assert(q === 5, "parenthesized compound assignment still works");

// An AssignmentExpression's own result is a value, so it is ~invalid~ as a
// target in turn: `(x = y) = 1` and `(x ??= y)++` are early SyntaxErrors.
//
// This case is separate from the operator cases above because the engine
// deliberately DOES leave a reference marker set on an assignment result: when
// the target is a register-cached local, the result IS that local's home
// register, and an enclosing operator has to know that to copy it to a temp
// instead of clobbering the variable (`(u = 45) > 0`). That register-aliasing
// hint and "is a valid assignment target" are different questions, so the
// verdict is tracked separately; the assertions below pin the split.
var atgOps = ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=",
              "&=", "|=", "^=", "&&=", "||=", "??="];
for (var ai = 0; ai < atgOps.length; ai++) {
    var inner = "(av " + atgOps[ai] + " bv)";
    assert(syntaxError("var av=1,bv=2; " + inner + " = 1"),
           inner + " = 1 is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; " + inner + " += 1"),
           inner + " += 1 is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; " + inner + "++"),
           inner + "++ is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; " + inner + "--"),
           inner + "-- is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; ++" + inner),
           "++" + inner + " is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; --" + inner),
           "--" + inner + " is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; for (" + inner + " in {}) ;"),
           "for (" + inner + " in {}) is a SyntaxError");
    assert(syntaxError("var av=1,bv=2; for (" + inner + " of []) ;"),
           "for (" + inner + " of []) is a SyntaxError");
}

// The aliasing hint the above must not disturb: an assignment whose value is
// consumed by an enclosing operator still reads the ASSIGNED value, and the
// target variable keeps it (b0fdc49c). If the target check were implemented by
// clearing the reference markers, the operator would write its result into the
// variable's own register and corrupt it.
var uu = 0;
assert(((uu = 45) > 0) === true, "(uu = 45) > 0 evaluates to true");
assert(uu === 45, "uu survives being an operand of >");
var nn = 1;
assert(((nn = 3) + 1) === 4, "(nn = 3) + 1 evaluates to 4");
assert(nn === 3, "nn survives being an operand of +");
var mm = 2;
assert(((mm *= 4) - 1) === 7, "(mm *= 4) - 1 evaluates to 7");
assert(mm === 8, "mm survives being an operand of -");

// Chained assignment stays legal: `a = b = 1` is AssignmentExpression in the
// RHS position, not the target position.
var c1, c2;
c1 = c2 = 7;
assert(c1 === 7 && c2 === 7, "chained assignment still works");
var d1, d2;
(d1) = (d2) = 8;
assert(d1 === 8 && d2 === 8, "chained assignment through parens still works");

// delete still deletes.
var delObj = { y: 1 };
assert(delete delObj.y === true, "delete returns true");
assert(!("y" in delObj), "delete actually removed the property");

print('assignment-target-type: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
