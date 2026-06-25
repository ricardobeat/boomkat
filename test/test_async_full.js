var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }
function done() { print("part1: " + pass + "/" + (pass + fail) + " passed"); }

async function simple() { return 42; }
var p1 = simple();
assert(typeof p1 === "object", "1 typeof");
assert(p1 instanceof Promise, "1 instanceof");

async function awaitVal(x) { return await x; }
var p2 = awaitVal(99);
assert(p2 instanceof Promise, "2 await");

async function noReturn() { var x = 1; }
var p3 = noReturn();
assert(p3 instanceof Promise, "3 no-return");

var asyncExpr = async function(x) { return x * 2; };
var p4 = asyncExpr(21);
assert(p4 instanceof Promise, "4 expr");

async function nested(a, b) { var x = await a; var y = await b; return x + y; }
var p5 = nested(10, 32);
assert(p5 instanceof Promise, "5 nested");

var p7 = (async function() { return 100; })();
assert(p7 instanceof Promise, "7 iife");

async function strAwait(s) { return await s; }
var p9 = strAwait("hello");
assert(p9 instanceof Promise, "9 string");

p1.then(function(v) { assert(v === 42, "v1=42"); });
p2.then(function(v) { assert(v === 99, "v2=99"); });
p3.then(function(v) { assert(v === undefined, "v3=undef"); });
p4.then(function(v) { assert(v === 42, "v4=42"); });
p5.then(function(v) { assert(v === 42, "v5=42"); });
p7.then(function(v) { assert(v === 100, "v7=100"); });
p9.then(function(v) { assert(v === "hello", "v9=hello"); done(); });
