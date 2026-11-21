"use strict";
// Strict global code whose block scopes compile away: what the blocks declare, a loop head's
// destructured binding, a block function, a class, must not land in the program's scope.
function assert(c, m) { if (!c) { print('FAIL: ' + m); throw new Error(m); } }
function refError(f) { try { f(); return false; } catch (e) { return e instanceof ReferenceError; } }
var value;
for (let [x] of [[34]]) { value = x; }
assert(typeof x === 'undefined' && value === 34, 'for-of head binding stays in its block');
for (let { k } of [{ k: 1 }]) value += k;
for (const key in { a: 1 }) value += key.length;
assert(typeof k === 'undefined' && typeof key === 'undefined' && value === 36, 'for-of and for-in heads');
assert(refError(() => f), 'block function before its block');
{ function f() { return 'f'; } assert(f() === 'f', 'block function in its block'); }
assert(refError(() => f), 'block function after its block');
switch (1) { case 1: function g() {} }
assert(refError(() => g), 'switch clause function');
{ class C {} assert(typeof C === 'function', 'block class'); }
assert(refError(() => C), 'block class after its block');
let total = 0;
for (let i = 0; i < 10; i++) { let sq = i * i; total += sq; }
assert(total === 285 && typeof i === 'undefined' && typeof sq === 'undefined', 'block loop');
print('global_block_bindings_strict: ok');
