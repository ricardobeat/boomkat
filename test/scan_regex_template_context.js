// The compiler's token pre-scans must read `/` and template substitutions the
// way the parser does. Each construct below sits inside a function
// declaration, whose body the hoisting and skipping scans walk before the
// parser compiles it. A scan that mis-lexes one of them rejects the whole file.

var failures = 0;
function check(name, got, want) {
    if (got !== want) {
        failures++;
        print("FAIL: " + name + ": got " + String(got) + ", want " + String(want));
    }
}

// --- regex literal after the `)` of a statement head ---

function regexAfterIfHead() { if (1) /}/.test("}"); z1 = 5; var z1; return z1; }
check("regex after if head, then hoisted var", regexAfterIfHead(), 5);
check("hoisted var did not leak", typeof globalThis.z1, "undefined");

function regexAfterWhileHead() { var n = 0; while (n++ < 1) /'/.test("a"); return n; }
check("regex with a quote after while head", regexAfterWhileHead(), 2);

function regexAfterForHead() { for (var i = 0; i < 1; i++) /{/.test("{"); return i; }
check("regex with a brace after for head", regexAfterForHead(), 1);

function regexAfterWithHead() { with ({}) /}/.test("}"); return 1; }
check("regex after with head", regexAfterWithHead(), 1);

function capturedAfterRegexHead() {
    if (1) /}/.test("}");
    var late = 7;
    return function () { return late; };
}
check("capture declared after a regex after an if head", capturedAfterRegexHead()(), 7);

// --- regex literal after the `}` of a statement block ---

function regexAfterBareBlock() { { } /}/.test("}"); z2 = 6; var z2; return z2; }
check("regex after a bare block", regexAfterBareBlock(), 6);

function regexAfterTryBlocks() { try { } finally { } /}/.test("}"); return 1; }
check("regex after try/finally blocks", regexAfterTryBlocks(), 1);

function regexAfterIfBlock() { if (1) { } /}/.test("}"); return 2; }
check("regex after an if block", regexAfterIfBlock(), 2);

function regexAfterFunctionDeclaration() {
    function inner() { }
    /}/.test("}");
    return 3;
}
check("regex after a function declaration", regexAfterFunctionDeclaration(), 3);

// --- regex literal after `of` in a for-of head ---

function regexAfterOf() {
    var seen = 0;
    for (var m of /}/.exec("}") || []) seen++;
    return seen;
}
check("regex after of", regexAfterOf(), 1);

// --- division stays division ---

function divisionAfterParen() { var a = 8, b = 2; { let q = (a) / b / 2; return q; } }
check("division after a parenthesised operand", divisionAfterParen(), 2);

function divisionAfterFunctionExpression() {
    var d = function () { } / 2;
    { let q = 1; return d !== d; }
}
check("division after a function expression body", divisionAfterFunctionExpression(), true);

function divisionAfterObjectLiteral() {
    var d = {} / 2;
    { let q = 1; return d !== d; }
}
check("division after an object literal", divisionAfterObjectLiteral(), true);

function divisionAfterCall() { var a = 6; { let q = Math.abs(a) / 3; return q; } }
check("division after a call", divisionAfterCall(), 2);

// --- template substitutions ---

function tdzAfterTemplate() {
    var s = `a${1}b`;
    try { return typeof q; } catch (e) { return e.name; }
    let q = 1;
}
check("let after a template with a substitution keeps its TDZ", tdzAfterTemplate(), "ReferenceError");

function tdzAfterTemplateWithObject() {
    var s = `a${ { x: 1 }.x }b`;
    try { return typeof q; } catch (e) { return e.name; }
    let q = 1;
}
check("let after a template whose substitution holds braces", tdzAfterTemplateWithObject(), "ReferenceError");

function tdzAfterNestedTemplate() {
    var s = `a${ `b${ 1 }c` }d`;
    try { return typeof q; } catch (e) { return e.name; }
    let q = 1;
}
check("let after nested templates", tdzAfterNestedTemplate(), "ReferenceError");

function tdzInBlockAfterTemplate() {
    { var s = `a${1}b${2}c`; try { return typeof q; } catch (e) { return e.name; } let q = 1; }
}
check("let in a block after a multi-substitution template", tdzInBlockAfterTemplate(), "ReferenceError");

function varAfterTemplate() {
    { var s = `a${1}b`; }
    { var hoisted = 9; }
    return hoisted;
}
check("var after a template substitution", varAfterTemplate(), 9);

function captureAfterTemplate() {
    var s = `a${1}b`;
    var late = 4;
    return function () { return late; };
}
check("capture declared after a template substitution", captureAfterTemplate()(), 4);

function classAfterTemplate() {
    var s = `a${1}b`;
    try { return typeof C; } catch (e) { return e.name; }
    class C { }
}
check("class after a template keeps its TDZ", classAfterTemplate(), "ReferenceError");

if (failures > 0) throw new Error(failures + " scan context check(s) failed");
print("scan_regex_template_context: all checks passed");
