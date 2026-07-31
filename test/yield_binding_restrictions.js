// `yield` binding/reference restrictions (ES2024 §13.1.1, §13.15).
//
// This engine is strict-only, so `yield` is ALWAYS a reserved word: it is
// never a BindingIdentifier, never an IdentifierReference, and never a label.
// Inside a generator it is the yield operator, and because a YieldExpression
// IS an AssignmentExpression it may only appear where the grammar expects one
// (`x = yield`, `f(yield)`), never as a unary operand or a non-leftmost
// binary/conditional operand (`!yield`, `1 + yield`, `yield ? a : b`).
//
// Runs unmodified under node (`node test/yield_binding_restrictions.js`) with
// the shim below, so the expectations are V8-verified.
if (typeof print === "undefined") { var print = function (s) { console.log(s); }; }

var pass = 0;
var fail = 0;

// Every source here is compiled through Function(), which parses in strict
// mode under node (the "use strict" prologue) and in this engine's only mode.
function rejects(label, src) {
    var threw = false;
    try {
        Function('"use strict";\n' + src);
    } catch (e) {
        threw = (e instanceof SyntaxError);
    }
    if (threw) { pass++; }
    else { fail++; print("FAIL: expected SyntaxError for " + label + " -- [" + src + "]"); }
}

function accepts(label, src) {
    try {
        Function('"use strict";\n' + src);
        pass++;
    } catch (e) {
        fail++;
        print("FAIL: expected " + label + " to parse -- [" + src + "] threw " + e);
    }
}

// --- `yield` is never a binding name or reference (outside a generator) ---
rejects("bare yield statement",      "yield;");
rejects("var yield",                 "var yield = 13;");
rejects("let yield",                 "let yield = 1;");
rejects("const yield",               "const yield = 1;");
rejects("function named yield",      "function yield() {}");
rejects("function param yield",      "function f(yield) {}");
rejects("arrow param default yield", "(x = yield) => {};");
rejects("class named yield",         "class yield {}");
rejects("catch param yield",         "try {} catch (yield) {}");
rejects("yield as label",            "yield: 1;");
rejects("yield identifier ref",      "yield + 1;");
rejects("object shorthand yield",    "var o = { yield };");
rejects("yield in 'in' rhs",         "'' in (yield);");

// --- `yield` in destructuring assignment patterns ---
rejects("obj shorthand dstr yield",  "0, { yield } = {};");
rejects("obj id init yield",         "0, { x = yield } = {};");
rejects("array elem init yield",     "0, [ x = yield ] = [];");
rejects("array elem target yield",   "0, [ x[yield] ] = [];");
rejects("for-in dstr obj id yield",  "for ({ yield } in [{}]) ;");
rejects("for-in dstr array yield",   "for ([ x = yield ] in [[]]) ;");

// --- yield is a Syntax Error in FormalParameters even inside a generator ---
rejects("gen param default yield",   "function *g() { 0, function(x = yield) {}; }");
rejects("nested fn param yield",     "function *g() { function f(x = yield) {} }");

// --- YieldExpression only where an AssignmentExpression is expected ---
function genRejects(label, body) { rejects(label, "function *g(){ " + body + " }"); }
function genAccepts(label, body) { accepts(label, "function *g(){ " + body + " }"); }

genRejects("void yield",             "void yield;");
genRejects("typeof yield",           "typeof yield;");
genRejects("logical not yield",      "!yield;");
genRejects("unary minus yield",      "-yield;");
genRejects("binary rhs yield",       "1 + yield;");
genRejects("logical or rhs yield",   "a || yield;");
genRejects("logical and rhs yield",  "a && yield;");
genRejects("yield as condition",     "yield ? 1 : 2;");
genRejects("yield weak binding",     "yield 3 + yield 4;");
genRejects("equality rhs yield",     "x = yield == 1;");

// --- ...and the accept side: these MUST keep parsing ---
genAccepts("bare yield",             "yield;");
genAccepts("yield operand",          "yield 1;");
genAccepts("yield delegate",         "yield* [1];");
genAccepts("assignment rhs",         "x = yield;");
genAccepts("compound assign rhs",    "x += yield;");
genAccepts("call argument",          "f(yield);");
genAccepts("array element",          "[yield];");
genAccepts("object property value",  "({ a: yield });");
genAccepts("computed key",           "var o = { [yield]: 1 };");
genAccepts("leftmost binary operand","yield + 1;");
genAccepts("comma operand",          "yield, 1;");
genAccepts("conditional branch",     "a ? yield : 1;");
genAccepts("return operand",         "return yield;");
genAccepts("member index",           "x[yield];");
genAccepts("parenthesized",          "void (yield);");
genAccepts("chained yield",          "yield yield 1;");
genAccepts("if condition",           "if (yield) {}");
genAccepts("throw operand",          "throw yield;");
genAccepts("spread operand",         "x = [...yield];");
genAccepts("template substitution",  "`${yield}`;");
genAccepts("parenthesized comma",    "x = (a, yield);");

// --- `yield` as a property NAME is always fine (IdentifierName, not a ref) ---
accepts("property name",             "var o = { yield: 1 }; o.yield;");
accepts("member assignment",         "var o = {}; o.yield = 1;");
accepts("method name",               "var o = { yield(){} };");
accepts("class method name",         "class C { yield(){} }");
accepts("getter name",               "var o = { get yield(){ return 1; } };");
accepts("identifier with prefix",    "var yielding = 1; yielding;");
accepts("generator method",          "var o = { *m(){ yield 1; } };");
accepts("class generator method",    "class C { *m(){ yield* [1]; } }");
accepts("class expr name binding",   "{ let x = class x {}; }");

// --- restricted names as assignment targets (same early-error family) ---
rejects("array target arguments",    "function f(){ [arguments] = []; }");
rejects("array target eval",         "function f(){ [eval] = []; }");
rejects("rest target arguments",     "function f(){ [...arguments] = []; }");
rejects("nested array target eval",  "function f(){ [[eval]] = [[]]; }");
rejects("obj prop target eval",      "function f(){ ({a: eval} = {}); }");
rejects("for-in array arguments",    "function f(){ for ([arguments] in [[]]) ; }");
rejects("for-of array arguments",    "function f(){ for ([arguments] of [[]]) ; }");
accepts("member named eval ok",      "function f(){ var o = {}; [o.eval] = []; }");
accepts("member named arguments ok", "function f(){ var o = {}; [o.arguments] = []; }");
accepts("plain array target",        "function f(){ var a; [a] = []; }");
accepts("name containing eval",      "function f(){ var evaluate; [evaluate] = []; }");

// --- for-in with a bare pattern is an AssignmentPattern, so it must both
//     accept member targets and assign to existing lvalues (not declare).
//     Built through Function() so that an engine which cannot even PARSE the
//     member-target form still reports counts instead of dying at load time. ---
function runtimeEquals(label, src, expected) {
    var got;
    try {
        got = String(Function('"use strict";\n' + src)());
    } catch (e) {
        got = "threw " + e;
    }
    if (got === expected) { pass++; }
    else { fail++; print("FAIL: " + label + " -- expected [" + expected + "] got [" + got + "]"); }
}

runtimeEquals("for-in bare pattern assigns to existing lvalue",
    "var log = [], x, src = { a: 1, b: 2 };" +
    "for ({ length: x } in src) { log.push(x); }" +
    "return log.join(',');", "1,1");

runtimeEquals("for-in bare pattern accepts a member target",
    "var obj = {}, src = { a: 1, b: 2 };" +
    "for ({ length: obj.p } in src) { }" +
    "return obj.p;", "1");

print("yield_binding_restrictions: " + pass + " passed, " + fail + " failed");
if (fail > 0) {
    print("SOME TESTS FAILED");
    throw new Error("FAIL");
}
