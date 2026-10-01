// Array literal elements are defined with INITELEM (immediate index). Each case
// checks length, holes and values for a literal shape the compiler or the
// threaded handler treats differently.
function check(actual, expected, what) {
    if (actual !== expected) {
        throw new Error(what + ': expected ' + expected + ', got ' + actual);
    }
}
function shape(a) {
    var s = a.length + ':';
    for (var i = 0; i < a.length; i++) s += (i in a ? String(a[i]) : '_') + ',';
    return s;
}

function literals(i) {
    return [
        shape([]), shape([1]), shape([1, 2, 3]), shape([,]), shape([1,]), shape([1,,]),
        shape([,,]), shape([,1]), shape([1,,2]), shape([1,,,]), shape([undefined]),
        shape([undefined, 1]), shape([1, undefined]), shape([i, i + 1, 'x' + i]),
        shape([null, true, false]),
    ].join('|');
}
var expected = '0:|1:1,|3:1,2,3,|1:_,|1:1,|2:1,_,|2:_,_,|2:_,1,|3:1,_,2,|3:1,_,_,|1:undefined,|2:undefined,1,|2:1,undefined,|3:5,6,x5,|3:null,true,false,';
for (var n = 0; n < 200; n++) check(literals(5), expected, 'literal shapes on pass ' + n);

// Spread mixed with element stores.
function spreads(a) { return shape([0, ...a, 9]) + shape([...a, ...a]) + shape([,...a]); }
check(spreads([1, 2]), '4:0,1,2,9,4:1,2,1,2,3:_,1,2,', 'spread');

// More elements than fit the immediate index (0..255) and than the inline block.
var big = [];
var src = 'big = [';
for (var i = 0; i < 300; i++) src += (i % 50 === 7 ? '' : i) + ',';
src += '];';
(0, eval)(src);
check(big.length, 300, 'big length');
check(big[299], 299, 'big last');
check(big[256], 256, 'big past immediate range');
check(7 in big, false, 'big hole');

// Strings and objects as elements stay alive across collections.
function heapElements(i) {
    var s = 'k' + i;
    var o = { i: i };
    return [s, o, [i], s + s, o];
}
function churn() {
    var keep = [];
    for (var i = 0; i < 4000; i++) {
        var a = heapElements(i);
        if (i % 40 === 0) keep.push(a);
        var junk = []; for (var k = 0; k < 6; k++) junk.push({ k: k });
    }
    var ok = true;
    for (var j = 0; j < keep.length; j++) {
        var a = keep[j], i = j * 40;
        ok = ok && a[0] === 'k' + i && a[1].i === i && a[2][0] === i && a[3] === 'k' + i + 'k' + i && a[4] === a[1];
    }
    return ok;
}
check(churn(), true, 'heap elements across GC');

// A literal defines its elements: setters and read-only entries on the
// prototype chain are not consulted.
var hits = 0;
Object.defineProperty(Array.prototype, '1', { set: function () { hits++; }, get: function () { return 'proto'; }, configurable: true });
var defined = [10, 20, 30];
check(hits, 0, 'prototype setter not called');
check(defined[1], 20, 'own element wins');
delete Array.prototype[1];

// Nested literals and literals as call arguments.
function nested(i) { return [[i], [[i + 1]], [i, [i, [i]]]]; }
check(JSON.stringify(nested(3)), '[[3],[[4]],[3,[3,[3]]]]', 'nested');
check(Math.max.apply(null, [3, 9, 4]), 9, 'literal as apply arguments');

// Pushing past the inline block keeps the elements.
function grow() {
    var a = [1, 2, 3];
    for (var i = 4; i <= 40; i++) a.push(i);
    return a.length === 40 && a[0] === 1 && a[39] === 40;
}
check(grow(), true, 'growth past the inline block');
