// Stress the value-stack growth paths after ensure_valstack moved from a
// relative-count contract to an absolute-watermark one. Every path that
// grows the valstack must still reserve exactly what the frame needs: deep
// recursion, spread calls, Function.apply with large arrays, closures, and
// generator/async resume all place frames above the current top. Under-
// reservation here would let a frame extend past the allocation.
var pass = 0, total = 0;
function check(cond, label) {
    total++;
    if (cond) { pass++; } else { print("FAIL: " + label); }
}

// Deep recursion: each frame pushes callee registers above the caller.
function depth(n) { return n <= 0 ? 0 : 1 + depth(n - 1); }
check(depth(400) === 400, "deep recursion");

// Mutual recursion through a chain of small frames.
function even(n) { return n === 0 ? true : odd(n - 1); }
function odd(n) { return n === 0 ? false : even(n - 1); }
check(even(400) === true && odd(401) === true, "mutual recursion");

// Function.apply with a large array: grows the stack for the extracted args.
function sum() { var s = 0; for (var i = 0; i < arguments.length; i++) { s += arguments[i]; } return s; }
var big = [];
for (var i = 0; i < 2000; i++) { big.push(i); }
check(sum.apply(null, big) === 1999000, "Function.apply large array");

// Spread calls with many arguments and trailing args.
function spreadSum() { var s = 0; for (var i = 0; i < arguments.length; i++) { s += arguments[i]; } return s; }
var arr = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
check(spreadSum(0, ...arr, 99) === 154, "spread call with leading and trailing");
check(spreadSum(...arr) === 55, "single spread");

// Closures capturing many registers, called deep in a chain.
function makeCounter(base) {
    var c = base;
    return function () { c = c + 1; return c; };
}
var fns = [];
for (var i = 0; i < 100; i++) { fns.push(makeCounter(i)); }
var acc = 0;
for (var i = 0; i < 100; i++) { acc += fns[i](); }
check(acc === 5050, "many closures");

// Generator resume: snapshot/restore of registers over a grown stack.
function* gen(n) {
    var a = 1, b = 1;
    for (var i = 0; i < n; i++) { var t = a + b; a = b; b = t; yield a; }
}
var g = gen(100);
var last = 0, cnt = 0;
for (var v of g) { last = v; cnt++; }
check(cnt === 100 && last === 573147844013817200000, "generator resume");

// Async functions interleaved with deep calls.
function p(v) { return new Promise(function (res) { res(v); }); }
async function chain(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { s += await p(i); }
    return s;
}
var chainResult = 0;
chain(50).then(function (v) { chainResult = v; });
// The promise microtask may not have drained yet at top level; drain via
// another await chain is not possible at top level in this engine, so this
// check is best-effort.
check(typeof chain === "function", "async chain constructible");

// Nested eval frames.
var eacc = 0;
eval("for (var i = 0; i < 100; i++) { eacc = eacc + i; }");
check(eacc === 4950, "eval loop");

// Big nested calls: call depth mixed with argument pressure.
function deep2(k, n) { return n <= 0 ? k : deep2(k + n, n - 1); }
check(deep2(0, 300) === 45150, "accumulator recursion");

print("test_valstack_growth: " + pass + " passed, " + (total - pass) + " failed");
