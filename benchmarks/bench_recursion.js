// Bench 2: Function call overhead — recursive fibonacci
function fib(n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}
var r = fib(20);
