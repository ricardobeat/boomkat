function check(value, expected, message) {
    if (value !== expected) throw new Error(message + ': ' + value);
}

var leaf = {
    elms: [3, 7, 11], x: 2, y: 3,
    at: function(index) { return this.elms[index]; },
    size: function() { return this.elms.length; },
    dot: function(v) { return this.x * v.x + this.y * v.y; }
};
function readLeaves() {
    check(leaf.at(1), 7, 'index');
    check(leaf.size(), 3, 'length');
    check(leaf.dot({ x: 4, y: 5 }), 23, 'dot');
}
for (var i = 0; i < 40; i++) readLeaves();

// An argument can replace the method after lookup; fallback keeps the earlier callee.
var order = '';
var savedAt = leaf.at;
function replaceAt() { order += 'arg'; leaf.at = function() { return 99; }; return 0; }
check(leaf.at(replaceAt()), 3, 'lookup precedes arguments');
check(leaf.at(0), 99, 'replacement');
leaf.at = savedAt;
check(order, 'arg', 'argument evaluated once');

function product(a, b) { return a * b + 1; }
function productSite(a, b) { return product(a, b); }
check(productSite(3, 4), 13, 'numeric');
var conversions = 0;
var numberObject = { valueOf: function() { conversions++; return 5; } };
check(productSite(numberObject, 2), 11, 'coercion fallback');
check(conversions, 1, 'coercion once');
var originalProduct = product;
product = function() { return 19; };
check(productSite(3, 4), 19, 'identity miss');
product = originalProduct;
if (!isNaN(productSite(2))) throw new Error('missing argument');

// Getters and Proxy traps run with the ordinary callee frame present.
var getterCalls = 0;
var receiver = { data: 8, peek: function() { return this.data; } };
function readPeek() { return receiver.peek(); }
check(readPeek(), 8, 'data read');
Object.defineProperty(receiver, 'data', { configurable: true, get: function getter() {
    getterCalls++;
    check(getter.caller, receiver.peek, 'getter caller');
    return 12;
} });
check(readPeek(), 12, 'accessor fallback');
check(getterCalls, 1, 'getter once');
var proxyCalls = 0;
var raw = { data: 17, peek: receiver.peek };
receiver = new Proxy(raw, { get: function(target, key) { proxyCalls++; return target[key]; } });
check(readPeek(), 17, 'proxy fallback');
check(proxyCalls, 2, 'proxy lookups once');

function choose(value) { return value ? 31 : 47; }
function chooseSite(value) { return choose(value); }
check(chooseSite(true), 31, 'true branch');
check(chooseSite(false), 47, 'false branch');
function uninitialized() { var value; return value; }
check(uninitialized(), undefined, 'frame initialization');
function strictReceiver() { 'use strict'; return this; }
function sloppyReceiver() { return this; }
check(strictReceiver(), undefined, 'strict this');
check(sloppyReceiver(), this, 'sloppy this');

var finallyCount = 0;
function protectedRead() {
    try { return leaf.at(0); } finally { finallyCount++; }
}
check(protectedRead(), 3, 'try return');
check(finallyCount, 1, 'finally');
var previousElms = leaf.elms;
leaf.elms = null;
try { protectedRead(); throw new Error('expected TypeError'); }
catch (error) { check(error instanceof TypeError, true, 'throw fallback'); }
check(finallyCount, 2, 'throw finally');
leaf.elms = previousElms;

// A prototype accessor and an indexed accessor cannot be replayed after a guard miss.
var indexCalls = 0;
Object.defineProperty(leaf.elms, '1', { configurable: true, get: function() { indexCalls++; return 21; } });
check(leaf.at(1), 21, 'indexed getter');
check(indexCalls, 1, 'indexed getter once');
var keyCalls = 0;
check(leaf.at({ toString: function() { keyCalls++; return '0'; } }), 3, 'key coercion');
check(keyCalls, 1, 'key coerced once');

// Inlined references must survive calls that collect or move the value stack.
function retained(value) { return value; }
function retainedSite(value) { return retained(value); }
for (var j = 0; j < 2000; j++) {
    var value = { text: 'inline-' + j };
    check(retainedSite(value), value, 'owned result');
    if (j % 20 === 0 && typeof gc === 'function') gc();
}
print('guarded bytecode inlining passed');
