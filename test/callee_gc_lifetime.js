// A running function must survive the loss of every other reference to it.
// A call through a global binding keeps the callee in a register without
// owning it, and a strict tail call slides the frame over the register that
// held its callee, so in both cases the frame's own reference is what keeps
// the function alive. Each callee here clears its binding, allocates enough
// to trigger a collection, then reads a captured variable through the
// function object.
"use strict";
var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

function churn() {
    var junk = [];
    for (var i = 0; i < 50; i++) { let j = i; junk.push(() => j); }
    return junk.length;
}

var viaGlobal;
function makeGlobal() {
    var secret = 40;
    viaGlobal = (n) => { viaGlobal = null; churn(); return secret + n; };
}
makeGlobal();
function callGlobal() { var r = viaGlobal(2); return r; }
check("a borrowed callee that clears its binding", callGlobal(), 42);
check("the binding stays cleared", viaGlobal, null);

var viaTail;
function makeTail() {
    var secret = 30;
    viaTail = function (n) { viaTail = null; churn(); return secret + n; };
}
makeTail();
function tailInto() { return viaTail(3); }
function callTail() { var r = tailInto(); return r; }
check("a tail callee that clears its binding", callTail(), 33);

var chain;
function makeChain() {
    var secret = 7;
    chain = function (n) {
        if (n === 0) { chain = null; churn(); return secret; }
        return chain(n - 1);
    };
}
makeChain();
function callChain() { var r = chain(5); return r; }
check("a chain of tail calls through a cleared binding", callChain(), 7);

// Self-recursive frames take no reference of their own: the outermost call's
// frame keeps the shared function alive for all of them.
var recurse;
function makeRecurse() {
    var secret = 5;
    recurse = function (n) {
        if (n === 0) { recurse = null; churn(); return secret; }
        return 1 + recurse(n - 1);
    };
}
makeRecurse();
function callRecurse() { var r = recurse(4); return r; }
check("self-recursion below a cleared binding", callRecurse(), 9);

var thrower;
function makeThrower() {
    var secret = "boom";
    thrower = function (n) {
        if (n === 0) { thrower = null; churn(); throw new Error(secret); }
        return thrower(n - 1);
    };
}
makeThrower();
function callThrower() {
    try { thrower(3); } catch (e) { return e.message; }
    return "no throw";
}
check("a throw unwinds frames whose callee is gone", callThrower(), "boom");

var finalizer;
function makeFinalizer() {
    var secret = 11;
    finalizer = function () {
        try { finalizer = null; churn(); return secret; } finally { churn(); }
    };
}
makeFinalizer();
function callFinalizer() { var r = finalizer(); return r; }
check("a return through finally with the callee gone", callFinalizer(), 11);

print("callee_gc_lifetime: " + passed + " passed");
