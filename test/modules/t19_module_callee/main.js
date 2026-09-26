// A call through a module-scope binding borrows the callee from the module
// environment instead of taking a reference. The environment outlives every
// call, and the running frame keeps the function alive even when the body
// reassigns the binding it was called through.
import { fib as importedFib } from './dep.js';

function assert(c, m) { if (!c) { throw new Error('FAIL: ' + m); } }

function fib(n) { return n <= 1 ? n : fib(n - 1) + fib(n - 2); }
assert(fib(20) === 6765, 'recursion through a module function');
assert(importedFib(20) === 6765, 'recursion inside an imported function');

let clearsItself = function (n) {
    if (n === 0) {
        clearsItself = null;
        const junk = [];
        for (let i = 0; i < 20000; i++) junk.push({ i, s: 'x' + i });
        return (() => 1)();
    }
    return clearsItself(n - 1) + 1;
};
assert(clearsItself(3) === 4, 'a callee that clears its own binding finishes');
assert(clearsItself === null, 'the binding stays cleared');

let calls = 0;
function counted() { calls++; return { calls }; }
for (let i = 0; i < 1000; i++) counted();
assert(counted().calls === 1001, 'an object result replaces the borrowed callee');
