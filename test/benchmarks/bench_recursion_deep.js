// Deep recursion benchmark (Fibonacci 32) — stress deeper call stacks
var N = 32;

function fib(n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

var result = fib(N);
print(result);
