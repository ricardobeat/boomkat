// Currying and partial application
// Tests currying, partial application, function factories.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Manual currying
function curry(fn) {
    return function(a) {
        return function(b) {
            return fn(a, b);
        };
    };
}

function add(a, b) { return a + b; }
var curriedAdd = curry(add);
assert(typeof curriedAdd(5) === "function", "curried returns function");
assert(curriedAdd(5)(3) === 8, "curried add 5+3=8");

// Partial application via bind
function multiply(a, b) { return a * b; }
var double = multiply.bind(null, 2);
assert(double(5) === 10, "bind partial: double(5)=10");
assert(double(7) === 14, "bind partial: double(7)=14");

// Triple curry
function curry3(fn) {
    return function(a) {
        return function(b) {
            return function(c) {
                return fn(a, b, c);
            };
        };
    };
}

function volume(l, w, h) { return l * w * h; }
var curriedVol = curry3(volume);
assert(curriedVol(2)(3)(4) === 24, "curried volume 2x3x4");
var box2 = curriedVol(2);
assert(box2(5)(6) === 60, "partial 2, then 5x6");

// Closure-based partial application
function partial(fn, firstArg) {
    return function(restArg) {
        return fn(firstArg, restArg);
    };
}

function greet(greeting, name) { return greeting + ", " + name + "!"; }
var hello = partial(greet, "Hello");
assert(hello("World") === "Hello, World!", "partial greet");
assert(hello("JS") === "Hello, JS!", "partial reuse");

var hey = partial(greet, "Hey");
assert(hey("there") === "Hey, there!", "different partial");

// Function factories
function makeMultiplier(factor) {
    return function(n) { return n * factor; };
}
var triple = makeMultiplier(3);
var tenTimes = makeMultiplier(10);
assert(triple(7) === 21, "factory triple(7)=21");
assert(tenTimes(5) === 50, "factory tenTimes(5)=50");

// Compose
function compose(f, g) {
    return function(x) { return f(g(x)); };
}
var add1 = function(x) { return x + 1; };
var mul2 = function(x) { return x * 2; };
var add1ThenMul2 = compose(mul2, add1);
assert(add1ThenMul2(3) === 8, "compose: (3+1)*2=8");

var mul2ThenAdd1 = compose(add1, mul2);
assert(mul2ThenAdd1(3) === 7, "compose: 3*2+1=7");

// Memoize
function memoize(fn) {
    var cache = {};
    return function(n) {
        if (!(n in cache)) { cache[n] = fn(n); }
        return cache[n];
    };
}
var callCount = 0;
var square = memoize(function(n) { callCount = callCount + 1; return n * n; });
assert(square(5) === 25, "memoize square(5)");
assert(square(5) === 25, "memoize cache hit");
assert(callCount === 1, "function called only once");
assert(square(3) === 9, "memoize square(3)");
assert(callCount === 2, "called twice for new input");

print("engine/currying: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
