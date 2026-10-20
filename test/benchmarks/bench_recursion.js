// Recursion benchmark (Fibonacci)
var N = 29;

function fib(n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

var result = fib(N);
print(result);
