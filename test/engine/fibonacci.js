// Fibonacci sequence
// Computes the nth Fibonacci number using iteration.

function fibonacci(n) {
    if (n <= 0) return 0;
    if (n === 1) return 1;
    var a = 0, b = 1;
    for (var i = 2; i <= n; i++) {
        var tmp = a + b;
        a = b;
        b = tmp;
    }
    return b;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(fibonacci(0) === 0, "fib(0)=0");
assert(fibonacci(1) === 1, "fib(1)=1");
assert(fibonacci(2) === 1, "fib(2)=1");
assert(fibonacci(10) === 55, "fib(10)=55, got " + fibonacci(10));
assert(fibonacci(20) === 6765, "fib(20)=6765, got " + fibonacci(20));
assert(fibonacci(30) === 832040, "fib(30)=832040, got " + fibonacci(30));

print("engine/fibonacci: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
