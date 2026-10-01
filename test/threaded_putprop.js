// `o.k = v` runs from the threaded burst once its inline cache is warm. Each
// case below warms the store site and then changes what the store has to honor.
function check(actual, expected, what) {
    if (actual !== expected) {
        throw new Error(what + ': expected ' + expected + ', got ' + actual);
    }
}

function setA(o, v) { o.a = v; }
function setAStrict(o, v) { 'use strict'; o.a = v; }

// Numeric, string and object values replacing each other in one slot.
function mixedValues() {
    var o = { a: 0 };
    var keep = [];
    for (var i = 0; i < 300; i++) {
        setA(o, i);
        setA(o, 'str' + i);
        var obj = { i: i };
        setA(o, obj);
        keep.push(o.a === obj);
        setA(o, null);
        setA(o, true);
    }
    return keep.every(function (x) { return x; }) && o.a === true;
}
check(mixedValues(), true, 'mixed values');

// A string stored over a string releases the old one; the survivor stays valid
// through a collection.
function stringChurn() {
    var o = { a: 'x' };
    var last;
    for (var i = 0; i < 5000; i++) {
        last = 'v' + i;
        setA(o, last);
        if (i % 500 === 0) { var junk = []; for (var k = 0; k < 200; k++) junk.push({ k: k }); }
    }
    return o.a === last && o.a === 'v4999';
}
check(stringChurn(), true, 'string churn');

// Shape changes after the site is warm.
function shapeChange() {
    var o = { a: 1, b: 2 };
    for (var i = 0; i < 100; i++) setA(o, i);
    delete o.a;
    setA(o, 'again');
    var p = { b: 1, a: 2 };
    for (var i = 0; i < 100; i++) setA(p, i);
    return o.a === 'again' && p.a === 99 && Object.keys(o).join() === 'b,a';
}
check(shapeChange(), true, 'shape change');

// Non-writable and accessor properties installed after warm-up.
function readonlyAndAccessors() {
    var o = { a: 1 };
    for (var i = 0; i < 100; i++) setAStrict(o, i);
    Object.defineProperty(o, 'a', { writable: false, value: 7 });
    var threw = false;
    try { setAStrict(o, 8); } catch (e) { threw = e instanceof TypeError; }
    var log = [];
    var q = { a: 1 };
    for (var i = 0; i < 100; i++) setA(q, i);
    Object.defineProperty(q, 'a', { set: function (v) { log.push(v); }, get: function () { return 0; }, configurable: true });
    setA(q, 'via setter');
    return threw && o.a === 7 && log.length === 1 && log[0] === 'via setter';
}
check(readonlyAndAccessors(), true, 'readonly and accessors');

// A frozen receiver, and a setter inherited from a prototype.
function frozenAndInherited() {
    var o = { a: 1 };
    for (var i = 0; i < 100; i++) setA(o, i);
    Object.freeze(o);
    setA(o, 'ignored');
    var log = [];
    var proto = { set a(v) { log.push(v); } };
    var child = Object.create(proto);
    for (var i = 0; i < 3; i++) setA(child, i);
    var own = Object.create(proto);
    own.a = 0;
    return o.a === 99 && log.length === 4 && !child.hasOwnProperty('a');
}
check(frozenAndInherited(), true, 'frozen and inherited');

// Arrays, functions, proxies and primitives as receivers.
function otherReceivers() {
    var arr = [1];
    var fn = function () {};
    var trapped = [];
    var proxy = new Proxy({}, { set: function (t, k, v) { trapped.push(k + '=' + v); t[k] = v; return true; } });
    for (var i = 0; i < 100; i++) {
        setA(arr, i); setA(fn, i); setA(proxy, i);
        setA(5, i); setA('s', i);
    }
    return arr.a === 99 && fn.a === 99 && trapped.length === 100 && trapped[99] === 'a=99';
}
check(otherReceivers(), true, 'other receivers');

// Length on an array goes through ArraySetLength.
function arrayLength() {
    var arr = [1, 2, 3, 4];
    function setLen(o, v) { o.length = v; }
    for (var i = 0; i < 100; i++) { setLen([1, 2, 3], 1); }
    setLen(arr, 2);
    return arr.length === 2 && arr[2] === undefined;
}
check(arrayLength(), true, 'array length');

// Constructor-style stores into fresh objects, with a collection mid-loop.
function Point(x, y, tag) { this.x = x; this.y = y; this.tag = tag; }
function constructors() {
    var list = [];
    for (var i = 0; i < 3000; i++) list.push(new Point(i, i * 2, 't' + i));
    var sum = 0;
    for (var i = 0; i < list.length; i++) sum += list[i].x + list[i].y + list[i].tag.length;
    return sum;
}
check(constructors(), 3000 * 2999 / 2 * 3 + (10 * 2 + 90 * 3 + 900 * 4 + 2000 * 5), 'constructors');
