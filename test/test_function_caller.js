function check(value, expected) {
    if (value !== expected) throw new Error('unexpected caller');
}
function leaf() { return leaf.caller; }
function outer() { return leaf(); }
check(outer(), outer);
check(leaf.caller, null);
function recursive(n) {
    if (n) return recursive(n - 1);
    return recursive.caller;
}
check(recursive(2), recursive);
function strictOuter() { 'use strict'; return leaf(); }
check(strictOuter(), null);
var threw = false;
try { strictOuter.caller; } catch (e) { threw = e instanceof TypeError; }
check(threw, true);
var holder = { method: function () {
    var saved = holder.method;
    delete holder.method;
    check(leaf(), saved);
} };
holder.method();
print('function caller: PASS');
