// A `var` initializer ending at a block's `}` must not consume that brace.
//
// hoist_decls scans a function body token-by-token to find its `var` and
// `function` declarations. For `var e = <expr>` it delegates to
// skip_expression, which stops at the token after the initializer. When the
// declarator has no terminating `;` its expression ends at the enclosing
// block's `}` (ASI), and that brace belongs to the caller's brace counter --
// exactly like the unmatched `)` case the same scan already pushed back.
//
// Swallowing it instead left the enclosing scan's brace_depth one too high, so
// the scan ran past the end of the body it was hoisting and pulled the FOLLOWING
// sibling function declarations into that body's scope. Those siblings were then
// compiled twice: once as inner functions of the wrong parent (capturing its
// registers) and once correctly. The surviving closures were the wrong ones, so
// every outer `var` they referenced read as `undefined` -- which is how
// lodash 4.17.21 failed with "Cannot read properties of undefined (reading
// 'call')": its `getRawTag` saw `hasOwnProperty`/`toString` as undefined.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// --- the lodash shape: a var-in-block with no `;`, then sibling declarations
//     that close over an outer binding declared AFTER them ---
function outer() {
    function withBlockVar(n) { { var e = 1 } return "wb" + e; }
    function readsCaptured() { return typeof CAP; }
    function readsCaptured2() { return CAP; }
    var CAP = "captured";
    return [withBlockVar(), readsCaptured(), readsCaptured2()].join(",");
}
check("blockVarSiblingCapture", outer(), "wb1,string,captured");

// --- same, but the swallowed brace is a try block's ---
function outerTry() {
    function t(n) { try { var e = 2 } catch (n) {} return "t" + e; }
    function reader() { return HIDDEN; }
    var HIDDEN = "hidden";
    return t() + "," + reader();
}
check("tryBlockVarSiblingCapture", outerTry(), "t2,hidden");

// --- an if-block and a loop body reach the same skip_expression path ---
function outerIf() {
    function f() { if (1) { var a = 3 } return a; }
    function g() { return V; }
    var V = 7;
    return f() + "," + g();
}
check("ifBlockVar", outerIf(), "3,7");

function outerWhile() {
    function f() { var i = 0; while (i < 1) { var b = 4; i++ } return b; }
    function g() { return W; }
    var W = 8;
    return f() + "," + g();
}
check("whileBlockVar", outerWhile(), "4,8");

// --- the sibling must be ONE function object, not two: a property stored on
//     the binding has to survive (a second compilation rebinds a fresh object) ---
function identity() {
    function pre() { { var z = 1 } return z; }
    function tagged() { return "tagged"; }
    tagged.stat = "kept";
    var probe = tagged.stat;
    return pre() + "," + probe + "," + tagged();
}
check("singleFunctionObject", identity(), "1,kept,tagged");

// --- the real getRawTag shape from lodash: siblings read outer vars bound to
//     builtin methods, through a function whose body has a var-in-try ---
function lodashShape() {
    function ki(n) {
        var t = bl.call(n, "x"), r = n.x;
        try { n.x = undefined; var e = !0 } catch (n) {}
        var u = xl.call(n);
        return e && (t ? (n.x = r) : delete n.x), u;
    }
    function tag(n) { return xl.call(n); }
    var bl = Object.prototype.hasOwnProperty;
    var xl = Object.prototype.toString;
    return ki({}) + "," + tag([]);
}
check("lodashGetRawTagShape", lodashShape(), "[object Object],[object Array]");

// --- declaration order §10.2.11: the LAST body of a repeated name wins, and
//     the overrun must not resurrect an earlier one ---
function dupNames() {
    function h() { { var q = 1 } return "first"; }
    function h() { return "second"; }
    function after() { return TAIL; }
    var TAIL = "tail";
    return h() + "," + after();
}
check("duplicateNameLastWins", dupNames(), "second,tail");

if (failures === 0) {
    print("PASS: var-in-block hoisting keeps sibling declarations in scope");
} else {
    print("FAILED: " + failures + " check(s)");
}
