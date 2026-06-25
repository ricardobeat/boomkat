// Async/await test suite — part 2: Promise integration, loops, chained calls
var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }
function done() { print("part2: " + pass + "/" + (pass + fail) + " passed"); }

async function conditional(flag) { if (flag) { return await 1; } return await 0; }
var p1 = conditional(true);
assert(p1 instanceof Promise, "1 conditional");

async function boolAwait(b) { return await b; }
var p2 = boolAwait(true);
assert(p2 instanceof Promise, "2 bool await");

async function objReturn() { return { key: "val" }; }
var p3 = objReturn();
assert(p3 instanceof Promise, "3 object return");

async function arrAwait() { return [1, await 2, 3]; }
var p4 = arrAwait();
assert(p4 instanceof Promise, "4 array await");

async function awaitResolved(x) { var v = await Promise.resolve(x); return v; }
var p5 = awaitResolved("data");
assert(p5 instanceof Promise, "5 Promise.resolve");

async function innerFn(x) { return x + 1; }
async function outerFn(y) { var a = await innerFn(y); return a * 2; }
var p6 = outerFn(5);
assert(p6 instanceof Promise, "6 async calls async");

async function loopSum(n) { var s = 0; for (var i = 0; i < n; i++) { s = s + await i; } return s; }
var p7 = loopSum(5);
assert(p7 instanceof Promise, "7 loop await");

async function catchReject() {
    try { var v = await Promise.reject("fail"); return "ok"; }
    catch (e) { return "caught"; }
}
var p8 = catchReject();
assert(p8 instanceof Promise, "8 catch reject");

p1.then(function(v) { assert(v === 1, "v1 cond=1"); });
p2.then(function(v) { assert(v === true, "v2 bool=true"); });
p3.then(function(v) { assert(v.key === "val", "v3 objKey=val"); });
p4.then(function(v) { assert(v[1] === 2, "v4 arr[1]=2"); });
p5.then(function(v) { assert(v === "data", "v5 resolve=data"); });
p6.then(function(v) { assert(v === 12, "v6 outer=12"); });
p7.then(function(v) { assert(v === 10, "v7 loop=10"); });
p8.then(function(v) { assert(v === "caught", "v8 catch=caught"); done(); });

// Known limitation: throw inside async function crashes VM
// async function thrower() { throw "boom"; }
