"use strict";
// A Declaration is not a Statement, so it cannot be the single-statement body
// of an if/else arm, a loop, or a labelled statement (ES2024 §14.4-§14.7,
// §14.13 admit `Statement` there, not `StatementListItem`).
//
// The engine rejected `function`, `function*`, `class`, `let` and `const` in
// that position by switching on the body's leading token, but `async` is a
// contextual keyword that lexes as a plain IDENTIFIER, so
// `if (x) async function f(){}` slipped through. The two-token lookahead that
// tells the declaration from an `async` identifier reference already happens
// in the statement dispatcher, so the check is made there.
//
// The accept half matters as much as the reject half: `async` remains a
// perfectly ordinary identifier, and a LineTerminator before `function`
// (§14.7's [no LineTerminator here]) splits the text into two statements.
//
// Runs unmodified under node (`node test/test_decl_in_statement_position.js`)
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

// --- every Declaration form is illegal as a bare body ---
var decls = [
    "function f(){}",
    "function* g(){}",
    "async function f(){}",
    "async function* g(){}",
    "class C{}",
    "let x = 1;",
    "const c = 1;"
];
var positions = [
    "if (1) @",
    "if (1) ; else @",
    "while (0) @",
    // Bounded rather than `for (;;)`: on an engine that wrongly ACCEPTS the
    // body, eval actually runs the loop, and an unbounded one would hang
    // instead of reporting a failure.
    "for (var i = 0; i < 1; i++) @",
    "for (var k in {}) @",
    "for (var k of []) @",
    "lbl: @"
];
for (var p = 0; p < positions.length; p++) {
    for (var d = 0; d < decls.length; d++) {
        rejects(positions[p].replace("@", decls[d]));
    }
}
// `do ... while` takes a Statement body too.
rejects("do async function f(){} while (0);");
rejects("do function f(){} while (0);");

// --- a var declaration IS a Statement, so it stays legal ---
accepts("if (1) var v1 = 1;");
accepts("while (0) var v2 = 1;");
accepts("for (;;) { break; }");

// --- a block makes any declaration legal again ---
accepts("if (1) { async function f(){} }");
accepts("if (1) { } else { async function f(){} }");
accepts("while (0) { async function* g(){} }");
accepts("lbl: { async function f(){} }");
accepts("for (;;) { async function f(){}; break; }");

// --- `async` is still an ordinary identifier ---
accepts("async function topLevel(){}");
accepts("if (1) async;");
accepts("var async = 1; if (1) async;");
accepts("if (1) asyncthing;");
accepts("if (1) async.foo;");
accepts("if (1) async[0];");
accepts("if (1) async(1);");
accepts("if (1) x = async function(){};");
accepts("if (1) x = async () => 1;");
accepts("while (0) async;");
accepts("lbl: async;");
accepts("if (1) x; else async;");
// [no LineTerminator here]: with a newline this is `async;` followed by a
// separate FunctionDeclaration, which is a StatementListItem at top level.
accepts("if (1) async\nfunction afterNewline(){}");

// --- the accepted forms must still WORK, not merely parse ---
if (1) { async function works(){ return 1; } assert(typeof works === "function", "block-wrapped async fn is defined"); }
var asyncIdent = 7;
if (1) asyncIdent;
assert(asyncIdent === 7, "`async` as an identifier still evaluates");

var ranBody = 0;
lbl: { async function inLabelBlock(){} ranBody++; }
assert(ranBody === 1, "labelled block containing an async fn still runs");

print("decl-in-statement-position: " + pass + " passed, " + fail + " failed");
if (fail > 0) { print("SOME TESTS FAILED"); throw new Error("FAIL"); }
