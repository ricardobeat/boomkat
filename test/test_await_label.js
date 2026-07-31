"use strict";
// `await` as a LabelIdentifier (ES2024 §13.1.1 / §14.13).
//
// A LabelIdentifier is an Identifier, and `await` IS one wherever it is not
// reserved: outside a module, outside an async function/arrow, and outside a
// class static block. So `await: ;` is a valid labelled statement in plain
// script code — the same rule that already lets `var await = 1;` through.
//
// `yield` gets no such relaxation: §13.1.1 reserves it in ALL strict-mode
// code, and this engine is strict-only, so `yield:` is always a SyntaxError.
//
// This was an OVER-rejection: the engine reached its label branch only for the
// IDENTIFIER token type, and `await` lexes as its own AWAIT token, so a
// perfectly legal label was refused.
//
// Runs unmodified under node (`node test/test_await_label.js`) with the same
// counts. The "use strict" directive above is required for parity: a direct
// eval inherits the caller's strictness, and node's CommonJS entry point is
// sloppy without it.

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

function accepts(source, msg) { assert(!syntaxError(source), "must accept " + (msg || source)); }
function rejects(source, msg) { assert(syntaxError(source), "must reject " + (msg || source)); }

// --- `await` is a legal label in script code ---
accepts("await: ;");
accepts("await: 1;");
accepts("label: await: ;");
accepts("await: { }");
accepts("function f() { await: ; }");
accepts("function* g() { await: ; }");
accepts("class C { m() { await: ; } }");
// The [Await] grammar parameter is re-fixed at every function boundary, so a
// plain function nested inside an async one gets the label back.
accepts("async function f() { function g() { await: ; } }");
// Still an identifier in every other position, which is the pre-existing rule
// this fix has to stay consistent with.
accepts("var await = 1;");
accepts("var await = 1; await: ;");

// --- `await` is reserved where the spec reserves it ---
rejects("async function f() { await: ; }");
rejects("async function* g() { await: ; }");
rejects("class C { static { await: ; } }");
// A label does not create a binding, so an inner `await:` inside an outer
// `await:`-labelled statement is a duplicate label, not an await problem.
rejects("await: { await: ; }", "duplicate label");

// --- `yield` is reserved in all strict code, so it is never a label ---
rejects("yield: ;");
rejects("function f() { yield: ; }");
rejects("function* g() { yield: ; }");

// --- other reserved words stay rejected as labels ---
rejects("let: ;");
rejects("static: ;");
rejects("implements: ;");
rejects("true: ;");
rejects("false: ;");
rejects("null: ;");
// `eval` and `arguments` are NOT reserved words, so they remain valid labels.
accepts("eval: ;");
accepts("arguments: ;");

// --- the label actually works at runtime, not just at parse time ---
var order = [];
await: {
    order.push("in");
    break await;
}
order.push("out");
assert(order.join(",") === "in,out", "break to an `await` label leaves the block");

var n = 0;
await: for (var i = 0; i < 5; i++) {
    if (i === 3) { break await; }
    n++;
}
assert(n === 3, "break out of an `await`-labelled loop");

var seen = 0;
await: for (var j = 0; j < 4; j++) {
    if (j % 2 === 0) { continue await; }
    seen++;
}
assert(seen === 2, "continue an `await`-labelled loop");

print("await-label: " + pass + " passed, " + fail + " failed");
if (fail > 0) { print("SOME TESTS FAILED"); throw new Error("FAIL"); }
