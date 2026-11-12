// A function calling itself in register mode (OptBuild.self_reg_calls): deep recursion past the
// register depth bound, which declines to framed calls, and exits deep inside the recursion.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
function depth(n) { return n == 0 ? 0 : 1 + depth(n - 1); }
function sum(n, k) { return n == 0 ? k : sum(n - 1, k + n); }
var t = 0;
for (var i = 0; i < 30; i++) t += fib(18);
print(t, fib(20));
for (var i = 0; i < 50; i++) t += depth(1000);
print(t, depth(3000));
for (var i = 0; i < 50; i++) t = sum(400, 0);
print(t, sum(300, 0.5), sum(500, 1e9 * 3));
