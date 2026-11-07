// Match arrays are built in one step once a pattern's result shape is known.
// They must be indistinguishable from arrays built property by property.
function eq(actual, expected, message) {
    var a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(message + ': got ' + a + ', expected ' + e);
}
function keys(m) { return Reflect.ownKeys(m); }
function desc(m, k) {
    var d = Object.getOwnPropertyDescriptor(m, k);
    return d === undefined ? 'absent' : [d.value, d.writable, d.enumerable, d.configurable];
}

// Repeat each case so the cached shape is used after the first result.
for (var round = 0; round < 4; round++) {
    var m = /(a)(b)?(c)/.exec('xacz');
    eq(keys(m), ['0', '1', '2', '3', 'length', 'index', 'input', 'groups'], 'own keys, unmatched group');
    eq(m.length, 4, 'length');
    eq([m[0], m[1], m[2], m[3]], ['ac', 'a', undefined, 'c'], 'elements');
    eq(1 in m && 2 in m && 3 in m, true, 'an unmatched group is still present');
    eq(m.index, 1, 'index');
    eq(m.input, 'xacz', 'input');
    eq(m.groups, undefined, 'groups');
    eq(desc(m, 'index'), [1, true, true, true], 'index descriptor');
    eq(desc(m, 'length'), [4, true, false, false], 'length descriptor');
    eq(Object.keys(m), ['0', '1', '2', '3', 'index', 'input', 'groups'], 'enumerable keys');
    eq(Array.isArray(m), true, 'is an array');
    eq(Object.getPrototypeOf(m) === Array.prototype, true, 'prototype');
    eq(m.slice(1), ['a', undefined, 'c'], 'slice');
    eq(JSON.stringify(m), '["ac","a",null,"c"]', 'JSON');

    var n = /b/.exec('abc');
    eq(keys(n), ['0', 'length', 'index', 'input', 'groups'], 'own keys, no groups');
    eq(n.length, 1, 'length 1');

    var q = /(?<x>a)(?<y>b)?/.exec('za');
    eq(keys(q), ['0', '1', '2', 'length', 'index', 'input', 'groups'], 'own keys, named');
    eq(Object.getPrototypeOf(q.groups), null, 'groups prototype');
    eq(Object.keys(q.groups), ['x', 'y'], 'group names');
    eq([q.groups.x, q.groups.y, 'y' in q.groups], ['a', undefined, true], 'group values');
    eq(q.index, 1, 'named index');

    var d = /(a)(b)?/d.exec('za');
    eq(d.indices[0], [1, 2], 'indices');
    eq(d.indices[2], undefined, 'indices, unmatched');
    eq(keys(d), ['0', '1', '2', 'length', 'index', 'input', 'groups', 'indices'], 'own keys with d');

    var e = /()()()()()()/.exec('');
    eq(e.length, 7, 'empty captures length');
    eq(e.slice(1).join(''), '', 'empty captures');
}

// Results are ordinary arrays that scripts can change.
var r = /(a)(b)?/.exec('a');
r.index = 7; r.extra = 1; r[5] = 'x'; r.push('p');
eq(r.index, 7, 'index is writable');
eq(r.length, 7, 'length after writes');
eq(keys(r).slice(-3), ['index', 'input', 'groups'].concat(['extra']).slice(-3), 'keys after adding');
delete r.index;
eq('index' in r, false, 'index deletable');
var r2 = /(a)(b)?/.exec('a');
eq(r2.index, 0, 'a later result is unaffected by changes to an earlier one');
eq(keys(r2), ['0', '1', '2', 'length', 'index', 'input', 'groups'], 'later result keys');
Object.defineProperty(r2, 'index', { value: 9, writable: false });
eq(/(a)(b)?/.exec('a').index, 0, 'defineProperty on one result leaves others');
r2.length = 1;
eq(r2.length, 1, 'length truncation');
eq(2 in r2, false, 'truncated element is gone');
eq(Object.isFrozen(Object.freeze(/a/.exec('a'))), true, 'freeze');
eq(Object.isFrozen(/a/.exec('a')), false, 'a fresh result is not frozen');

// More unmatched sets and capture counts than the shape cache holds.
var shapes = [];
for (var mask = 0; mask < 64; mask++) {
    var src = '', input = '';
    for (var g = 0; g < 6; g++) {
        src += (mask >> g & 1) ? '(x)?' : '(y)';
        input += (mask >> g & 1) ? '' : 'y';
    }
    var res = new RegExp(src).exec(input);
    var expect = ['0'];
    for (var g = 0; g < 6; g++) expect.push(String(g + 1));
    expect.push('length', 'index', 'input', 'groups');
    eq(keys(res), expect, 'mask ' + mask);
    for (var g = 0; g < 6; g++) {
        eq(res[g + 1], (mask >> g & 1) ? undefined : 'y', 'mask ' + mask + ' group ' + g);
        eq(g + 1 in res, true, 'present ' + mask + ' ' + g);
    }
}

// Substrings are ordinary strings: usable as keys and equal to their literals.
var o = {};
var words = 'alpha beta gamma delta alpha beta'.match(/\w+/g);
for (var i = 0; i < words.length; i++) o[words[i]] = (o[words[i]] || 0) + 1;
eq(o, { alpha: 2, beta: 2, gamma: 1, delta: 1 }, 'slices as property keys');
eq(/(\w+) (\w+)/.exec('alpha beta')[2] === 'beta', true, 'slice equals literal');
eq(({ beta: 1 }).hasOwnProperty(/(\w+) (\w+)/.exec('alpha beta')[2]), true, 'slice finds a literal key');
var whole = 'whole';
eq(/whole/.exec(whole)[0] === whole, true, 'a whole-string match');
eq(/^(.*)$/.exec(whole)[1] === whole, true, 'a whole-string capture');

// Slice results survive allocation pressure between creation and use.
var keep = [];
for (var i = 0; i < 2000; i++) {
    var t = /(\d+)-(\d+)/.exec('n ' + i + '-' + (i + 1) + ' tail');
    keep.push(t);
    if (i % 100 === 0) { var junk = []; for (var j = 0; j < 500; j++) junk.push({ a: j }); }
}
for (var i = 0; i < 2000; i += 97) eq([keep[i][1], keep[i][2]], [String(i), String(i + 1)], 'kept result ' + i);

// A different realm-wide change: a getter on Array.prototype must not show on results.
Object.defineProperty(Array.prototype, 'index', { get: function () { return 'proto'; }, configurable: true });
eq(/a/.exec('a').index, 0, 'own index shadows the prototype');
delete Array.prototype.index;

// The substring cache must not hand back a string the collector has freed.
(function () {
    var base = '';
    for (var i = 0; i < 4000; i++) base += String.fromCharCode(97 + (i * 7 + (i >> 3)) % 26);
    var re = /(\w{2,9})/g, bad = 0, last;
    for (var round = 0; round < 60; round++) {
        var text = base.substring(round * 13 % 100) + round;
        re.lastIndex = 0;
        var m;
        while ((m = re.exec(text)) !== null && re.lastIndex < 600) {
            var s = m[1];
            if (text.substr(m.index, s.length) !== s) bad++;
            last = s;
        }
        var junk = [];
        for (var j = 0; j < 3000; j++) junk.push('k' + j + round);
    }
    eq(bad, 0, 'substring cache returned a wrong string');
})();

// An unmatched group is present with the value undefined; reads, `in` and
// redefinition of that index must keep working after the fast read.
(function () {
    for (var i = 0; i < 20; i++) {
        var m = /(a)(x)?(b)/.exec('ab');
        if (m[1] !== 'a' || m[2] !== undefined || m[3] !== 'b') throw new Error('FAIL unmatched read');
        if (!(2 in m) || !m.hasOwnProperty(2)) throw new Error('FAIL unmatched presence');
    }
    var m = /(a)(x)?(b)/.exec('ab');
    Object.defineProperty(m, 2, { get: function () { return 'got'; }, configurable: true });
    if (m[2] !== 'got') throw new Error('FAIL accessor on unmatched index');
    m = /(a)(x)?(b)/.exec('ab');
    m[2] = 'set';
    if (m[2] !== 'set') throw new Error('FAIL write to unmatched index');
})();
