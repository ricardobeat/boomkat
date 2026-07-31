// Mutual recursion / Deep call patterns
// Tests mutual recursion, trampoline-like patterns, deep stacks.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Hofstadter Female/Male sequences (mutual recursion)
// F(0) = 1;  F(n) = n - M(F(n-1))  for n > 0
// M(0) = 0;  M(n) = n - F(M(n-1))  for n > 0
function F(n) {
    if (n === 0) return 1;
    return n - M(F(n - 1));
}
function M(n) {
    if (n === 0) return 0;
    return n - F(M(n - 1));
}

assert(F(0) === 1, "F(0)=1");
assert(M(0) === 0, "M(0)=0");
assert(F(1) === 1, "F(1)=1");
assert(M(1) === 0, "M(1)=0");
assert(F(2) === 2, "F(2)=2");
assert(M(2) === 1, "M(2)=1");
assert(F(10) === 6, "F(10)=6");
assert(M(10) === 6, "M(10)=6");

// Deep linear recursion (not tail-optimized in JS)
function sumTo(n) {
    if (n <= 0) return 0;
    return n + sumTo(n - 1);
}
assert(sumTo(100) === 5050, "sumTo(100)=5050");
assert(sumTo(200) === 20100, "sumTo(200)=20100");

// Tree recursion: Fibonacci
function fib(n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}
assert(fib(0) === 0, "fib(0)");
assert(fib(1) === 1, "fib(1)");
assert(fib(10) === 55, "fib(10)=55");
assert(fib(20) === 6765, "fib(20)=6765");

// Indirect recursion: isEven/isOdd
function isEven(n) {
    if (n === 0) return true;
    return isOdd(n - 1);
}
function isOdd(n) {
    if (n === 0) return false;
    return isEven(n - 1);
}
assert(isEven(4) === true, "isEven(4)");
assert(isEven(7) === false, "isEven(7)");
assert(isOdd(3) === true, "isOdd(3)");
assert(isOdd(8) === false, "isOdd(8)");

// Callback depth: nested function calls
function chain(depth, fn) {
    if (depth <= 0) return fn();
    return chain(depth - 1, function() { return fn() + 1; });
}
assert(chain(0, function() { return 0; }) === 0, "chain(0)=0");
assert(chain(5, function() { return 0; }) === 5, "chain(5)=5");
assert(chain(50, function() { return 0; }) === 50, "chain(50)=50");

// Closure accumulation through recursion
function makeChain(n) {
    if (n <= 0) return function(x) { return x; };
    var inner = makeChain(n - 1);
    return function(x) { return inner(x) + 1; };
}
assert(makeChain(0)(0) === 0, "makeChain(0)(0)");
assert(makeChain(3)(0) === 3, "makeChain(3)(0)=3");
assert(makeChain(10)(5) === 15, "makeChain(10)(5)=15");

print("engine/mutual_recursion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
