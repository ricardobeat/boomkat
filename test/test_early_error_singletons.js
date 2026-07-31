// Three unrelated early errors that share only their shape: a production the
// parser accepted because the restriction lives in the grammar rather than in
// any check the parser was making.
//
//   §13.15.1  An AssignmentExpression has AssignmentTargetType ~invalid~, so
//             `(a = b) = 1` is a SyntaxError. Parentheses PRESERVE
//             AssignmentTargetType — `(a) = 1` is legal — so this cannot be
//             expressed with the parenthesized-ness of the target.
//
//   §14.3     `get PropertyName ( ) { }` and
//             `set PropertyName ( PropertySetParameterList ) { }` where
//             `PropertySetParameterList : FormalParameter`. A getter takes no
//             parameter; a setter takes exactly one, and being a
//             FormalParameter rather than a FormalParameterList it may not be
//             a rest parameter. Defaults and patterns ARE FormalParameters.
//
//   §14.7.5   `for ( [lookahead ∉ { let [, async of }] LeftHandSideExpression
//             of AssignmentExpression )`. The token pair `async of` at the
//             head's start is excluded, so a variable named `async` cannot be
//             a for-of target without parenthesizing it.
//
// Every expectation matches `node --check` except one, and every expectation
// matches QuickJS except two; in both cases the other engine is the outlier:
//
//   - node also rejects `for (o.async of [1])`, whose head does not START
//     with `async`. The restriction is a 2-token lookahead at the head's
//     start, so this is legal; QuickJS agrees with us.
//   - QuickJS accepts `set a(...r)`. PropertySetParameterList is a
//     FormalParameter, which a rest parameter is not, so it is a SyntaxError;
//     node agrees with us.

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

// --- §13.15.1 an assignment is not an assignment target -------------------
assert(syntaxError("var a, b = 2; (a = b) = 1;"), "simple assignment as a target");
assert(syntaxError("var a, b; ((a = b)) = 1;"), "doubly parenthesized");
assert(syntaxError("var a, b; (a += 1) = 2;"), "compound assignment as a target");
assert(syntaxError("var a, b; (a ||= b) = 1;"), "logical-or assignment as a target");
assert(syntaxError("var a, b; (a &&= b) = 1;"), "logical-and assignment as a target");
assert(syntaxError("var a, b; (a ??= b) = 1;"), "nullish assignment as a target");
assert(syntaxError("var o = {}, b; (o.x = b) = 1;"), "member assignment as a target");

assert(!syntaxError("var a, b = 2; (a) = 1;"), "a parenthesized identifier is a target");
assert(!syntaxError("var o = {}; (o.x) = 1;"), "a parenthesized member is a target");
assert(!syntaxError("var a, b; a = b = 1;"), "a right-nested assignment");
assert(!syntaxError("var a, b; (a = b) + 1;"), "an assignment as a binary operand");
assert(!syntaxError("var n = 1; (n *= 0.3) > 0;"), "a compound assignment as an operand");
assert(!syntaxError("var a; a = 1, a = 2;"), "two assignments in a comma list");

// --- §14.3 accessor arity -------------------------------------------------
assert(syntaxError("0, { get a(param) {} };"), "getter with a parameter");
assert(syntaxError("0, { get a(param = null) {} };"), "getter with a defaulted parameter");
assert(syntaxError("0, { get a(...r) {} };"), "getter with a rest parameter");
assert(syntaxError("0, { set a() {} };"), "setter with no parameter");
assert(syntaxError("0, { set a(v, w) {} };"), "setter with two parameters");
assert(syntaxError("0, { set a(...r) {} };"), "setter with a rest parameter");
assert(syntaxError("class C { get a(p) {} }"), "class getter with a parameter");
assert(syntaxError("class C { set a() {} }"), "class setter with no parameter");
assert(syntaxError("class C { set a(v, w) {} }"), "class setter with two parameters");
assert(syntaxError("class C { set a(...r) {} }"), "class setter with a rest parameter");

assert(!syntaxError("0, { get a() { return 1 } };"), "getter with no parameter");
assert(!syntaxError("0, { set a(v) {} };"), "setter with one parameter");
assert(!syntaxError("0, { set a(v = 1) {} };"), "setter with a defaulted parameter");
assert(!syntaxError("0, { set a([x, y]) {} };"), "setter with an array pattern");
assert(!syntaxError("0, { set a({ x }) {} };"), "setter with an object pattern");
assert(!syntaxError("0, { a(x, y) {} };"), "an ordinary method is unrestricted");
assert(!syntaxError("0, { get: 1, set: 2 };"), "get/set as ordinary property keys");
assert(!syntaxError("class C { static get a() {} static set a(v) {} }"), "static accessors");
assert(!syntaxError("class C { #x; get x() { return this.#x } set x(v) { this.#x = v } }"),
       "private-backed accessors");

// --- §14.7.5 `async of` is excluded from a for-of head ---------------------
assert(syntaxError("var async; for (async of [1]) ;"), "bare `async` as a for-of target");

assert(!syntaxError("var async; for ((async) of [1]) ;"), "parenthesized `async` is fine");
assert(!syntaxError("var o = {}; for (o.async of [1]) ;"), "a head not STARTING with async");
assert(!syntaxError("var async; for (async in {}) ;"), "`async` is fine in a for-in head");
assert(!syntaxError("for (var async of [1]) ;"), "a declared `async` binding is fine");
assert(!syntaxError("for (let async of [1]) ;"), "a lexical `async` binding is fine");
assert(!syntaxError("for (async of => 1; false;) ;"), "`async of => …` is a call, not a for-of");

print("=== Results:", pass, "pass,", fail, "fail ===");
