// Indexed reads of an array index held in the named table rather than the
// dense part: a RegExp match array's non-participating groups, an index
// promoted by defineProperty, and holes that must still reach the prototype.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

var re = /(a)(x)?(b)(y)?/;
function sum(m) {
    var out = [];
    for (var j = 0; j < m.length; j++) out.push(m[j] === undefined ? 'u' : m[j]);
    return out.join(',');
}
for (var i = 0; i < 300; i++) {
    var m = re.exec('zab');
    if (i === 0 || i === 299) {
        ok(sum(m) === 'ab,a,u,b,u', 'match array elements #' + i + ': ' + sum(m));
        ok(2 in m && 4 in m, 'unmatched groups are own properties #' + i);
    }
}

// An accessor at a named index is called, not read as a slot.
function readAll(arr) { var r = []; for (var k = 0; k < arr.length; k++) r.push(arr[k]); return r; }
var calls = 0;
var acc = [1, 2, 3];
Object.defineProperty(acc, 1, { get: function () { calls++; return 'got'; }, configurable: true });
for (var i = 0; i < 300; i++) readAll(acc);
ok(readAll(acc).join() === '1,got,3', 'getter at index');
ok(calls === 301, 'getter called every read: ' + calls);

// A non-enumerable data property promoted to the named table.
var ne = ['p', 'q', 'r'];
Object.defineProperty(ne, 1, { value: undefined, enumerable: false });
ne[2] = undefined;
for (var i = 0; i < 300; i++) readAll(ne);
ok(readAll(ne).join('|') === 'p||', 'named undefined index');
ok(1 in ne && Object.keys(ne).join() === '0,2', 'promoted index stays non-enumerable');

// A hole with an inherited value still reads through the prototype.
Array.prototype[3] = 'inherited';
var holey = [0, 1, 2, , 4];
Object.defineProperty(holey, 1, { value: 'one', writable: true, enumerable: true, configurable: true });
var seen;
for (var i = 0; i < 300; i++) seen = readAll(holey);
ok(seen.join() === '0,one,2,inherited,4', 'hole falls through to prototype: ' + seen.join());
delete Array.prototype[3];
ok(readAll(holey)[3] === undefined, 'prototype index removed');

print(fail === 0 ? 'PASS ' + pass : 'FAIL ' + fail);
