function check(actual, expected, message) {
    if (actual !== expected) throw new Error(message + ': ' + actual);
}

function assign(o, k, value) {
    o.x = value;
    return o[k] = value + 1;
}
var o = {};
check(assign(o, 'y', 4), 5, 'assignment result');
check(o.x, 4, 'dot store');
check(o.y, 5, 'computed store');

function compound(o, k) {
    o.x += 3;
    o.x -= 1;
    o[k] *= 2;
    o[k] /= 3;
    o[k] %= 5;
    o[k] **= 2;
    o[k] <<= 2;
    o[k] >>= 1;
    o[k] >>>= 1;
    o[k] |= 8;
    o[k] &= 11;
    return o[k] ^= 2;
}
check(compound({ x: 1 }, 'x'), 10, 'compound operators');

function updates(o, k) {
    var a = o.x++;
    var b = ++o[k];
    var c = o[k]--;
    var d = --o.x;
    o.x++;
    o[k]--;
    return a + b + c + d;
}
o = { x: '3' };
check(updates(o, 'x'), 16, 'numeric update results');
check(o.x, 3, 'update stores');
o = { x: 3n };
check(updates(o, 'x'), 16n, 'BigInt update results');
check(o.x, 3n, 'BigInt update stores');

function keepHome(value) {
    var base = {}, key = 'x';
    base[key] = value;
    base.x = key;
    return base.x + key;
}
check(keepHome(9), 'xx', 'base and key home registers');

var log = '';
var key = { toString: function () { log += 'k'; return 'x'; } };
var accessor = {
    get x() { log += 'g'; return '4'; },
    set x(v) { log += 's' + v; }
};
function rhs() { log += 'r'; return 2; }
function writeAccessor(o, k) { return o[k] = rhs(); }
function addAccessor(o, k) { return o[k] += rhs(); }
function updateAccessor(o, k) { return o[k]++; }
check(writeAccessor(accessor, key), 2, 'setter assignment result');
check(log, 'rks2', 'plain assignment skips getter');
log = '';
check(addAccessor(accessor, 'x'), '42', 'compound result');
check(log, 'grs42', 'compound reads before RHS');
log = '';
check(updateAccessor(accessor, 'x'), 4, 'postfix coerces old value');
check(log, 'gs5', 'update reads before store');
check(typeof key, 'object', 'key home survives coercion');

function retainKey(o, k) { o[k] += 1; return typeof k; }
check(retainKey({ x: 1 }, key), 'object', 'compound preserves key binding');

function strictThis() { 'use strict'; return this; }
function storeCall(o) { o.x = strictThis(); return o.x; }
check(storeCall({}), undefined, 'target receiver does not leak into RHS call');

function nestedStore(o, p, value) { return o.x = p.y = value; }
first = {}; second = {};
check(nestedStore(first, second, 8), 8, 'nested assignment result');
check(first.x + second.y, 16, 'nested assignment stores');

function identity(o) { return o; }
function chained(o) {
    identity(o).inner.x = 3;
    identity(o).inner.x += 2;
    return identity(o).inner.x++;
}
o = { inner: {} };
check(chained(o), 5, 'call-result target');
check(o.inner.x, 6, 'chained store');

function replaceBase(o, replacement) {
    o.x = (o = replacement);
    return o;
}
var first = {}, second = {};
check(replaceBase(first, second), second, 'RHS replaces binding');
check(first.x, second, 'reference keeps original base');
check(second.x, undefined, 'replacement receives no store');

function replaceInKey(o, replacement) {
    o[(o = replacement) ? 'x' : 'y'] = 7;
    return o;
}
first = {}; second = {};
check(replaceInKey(first, second), second, 'key replaces binding');
check(first.x, 7, 'reference survives key evaluation');
check(second.x, undefined, 'key replacement receives no store');

function replaceKey(o, k) { o[k] = (k = 'y'); return k; }
first = {};
check(replaceKey(first, 'x'), 'y', 'RHS replaces key binding');
check(first.x, 'y', 'reference keeps original key');
check(first.y, undefined, 'replacement key receives no store');

function replaceCompound(o, replacement) {
    return o.x += ((o = replacement) ? replacement.x : 0);
}
first = { x: 3 }; second = { x: 4 };
check(replaceCompound(first, second), 7, 'compound reads original value');
check(first.x, 7, 'compound stores to original base');
check(second.x, 4, 'compound replacement receives no store');

console.log('ok');
