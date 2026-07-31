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
        print("FAIL:", msg);
    }
}

assert(syntaxError("class A { accessor\nx = 1 }"), "line break after accessor");
assert(syntaxError("using\nx = null"), "line break after using");
assert(!syntaxError("class A { accessor; }"), "ordinary accessor field");
assert(!syntaxError("class B { accessor = 1; }"), "initialized accessor field");

// Restricted productions: `[no LineTerminator here]` is not an ASI opportunity,
// the whole construct is a SyntaxError rather than falling back to a shorter
// form. ES2024 §14.14 (throw), §15.3 (arrow), §15.5 (yield).
assert(syntaxError("throw\n1;"), "line break after throw");
assert(syntaxError("var af = x\n=> x;"), "line break before => (parenless, expr body)");
assert(syntaxError("var af = x\n=> {};"), "line break before => (parenless, block body)");
assert(syntaxError("var af = ()\n=> {};"), "line break before => (empty params)");
assert(syntaxError("var af = (a, b)\n=> a;"), "line break before => (multiple params)");
assert(syntaxError("var af = ({a})\n=> a;"), "line break before => (destructured param)");
assert(syntaxError("function* g() { yield\n* 1 }"), "line break before yield*");
assert(syntaxError("var o = { *g() { yield\n* 1 } };"), "line break before yield* in a method");

// ...and the shapes that must keep parsing. A line terminator after a bare
// `yield` still permits a following statement that cannot continue the
// expression (`+ 1` is a valid ExpressionStatement, `* 1` is not), and
// `throw`/`=>` with no line break are of course unaffected.
assert(!syntaxError("throw 1;"), "throw on one line");
assert(!syntaxError("function* g() { yield * [1] }"), "yield* on one line");
assert(!syntaxError("function* g() { yield\n+ 1 }"), "yield then a unary-plus statement");
assert(!syntaxError("function* g() { yield\n1 }"), "yield then an expression statement");
assert(!syntaxError("function* g() { (yield)\n* 1 }"), "parenthesized yield is a binary operand");
assert(!syntaxError("var af = x => x;"), "arrow on one line");
// `()` is not an expression on its own, so a newline before `=>` leaves an
// empty parenthesized expression: still a SyntaxError, just a different one.
assert(syntaxError("var af = ()\n; var b = 1;"), "empty parens with no =>");
assert(!syntaxError("var af = (1)\n; var b = 1;"), "non-empty parens not followed by =>");

print("=== Results:", pass, "pass,", fail, "fail ===");
