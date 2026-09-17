// An array rest whose target is a member expression (§13.15.5.5).
//
// The rest array is built up by pushing each remaining iterator value into it,
// so the register holding it has to survive the iterator's `next()` call. A
// call writes its callee, its receiver and its arguments starting at its own
// result register, so an array allocated at the current watermark sits inside
// that window and is overwritten on the first step. Every leaf but this one
// gets a register from its binding, which is already below the window; a
// member target has no binding.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) {
    var as = JSON.stringify(a), bs = JSON.stringify(b);
    ok(as === bs, m + ' (got ' + as + ', want ' + bs + ')');
}

// An iterator that is not a plain array, so the engine's array-iterator fast
// path does not apply and the generic next()/done/value protocol runs.
function iter(n) {
    var i = 0;
    return {
        [Symbol.iterator]: function () {
            return { next: function () {
                i++;
                return i <= n ? { value: i, done: false } : { done: true };
            } };
        }
    };
}

var o;

o = {}; [...o.r] = iter(0);
eq(o.r, [], 'rest alone, empty');
o = {}; [...o.r] = iter(3);
eq(o.r, [1, 2, 3], 'rest alone');

o = {}; [, ...o.r] = iter(0);
eq(o.r, [], 'elision then rest, iterator already done');
o = {}; [, ...o.r] = iter(1);
eq(o.r, [], 'elision consumes the only value');
o = {}; [, ...o.r] = iter(3);
eq(o.r, [2, 3], 'elision then rest');
o = {}; [, , ...o.r] = iter(1);
eq(o.r, [], 'two elisions past the end');
o = {}; [, , ...o.r] = iter(4);
eq(o.r, [3, 4], 'two elisions then rest');

o = {}; [o.a, ...o.r] = iter(1);
eq([o.a, o.r], [1, []], 'member element then member rest');
o = {}; [o.a, ...o.r] = iter(3);
eq([o.a, o.r], [1, [2, 3]], 'member element then member rest, more values');
o = {}; var v; [v, ...o.r] = iter(3);
eq([v, o.r], [1, [2, 3]], 'plain element then member rest');
o = {}; [o.a, , ...o.r] = iter(4);
eq([o.a, o.r], [1, [3, 4]], 'member element, elision, member rest');

// A computed key names the target property.
o = {}; var k = 'x'; [...o[k]] = iter(2);
eq(o.x, [1, 2], 'computed member rest');
o = {}; [, ...o[k]] = iter(2);
eq(o.x, [2], 'elision then computed member rest');

// A nested array target holds its own rest.
var arr;
arr = []; [, ...arr[0]] = iter(3);
eq(arr[0], [2, 3], 'rest into an array element');

// A setter sees the finished array, once.
var seen = 'NOTSET', calls = 0;
var withSetter = { set r(v) { calls++; seen = v; } };
[, ...withSetter.r] = iter(1);
ok(calls === 1, 'the setter runs once (got ' + calls + ')');
eq(seen, [], 'the setter receives the array');

var seen2;
var withSetter2 = { set r(v) { seen2 = v; } };
[, , ...withSetter2.r] = iter(4);
eq(seen2, [3, 4], 'the setter receives the remaining values');

// The iterator is stepped exactly as many times as the pattern requires: once
// per elision, once per element, and once more to see done.
function counted(n) {
    var i = 0, calls = 0;
    var it = {
        [Symbol.iterator]: function () {
            return { next: function () {
                calls++; i++;
                return i <= n ? { value: i, done: false } : { done: true };
            } };
        }
    };
    it.calls = function () { return calls; };
    return it;
}

var c = counted(3);
o = {}; [, ...o.r] = c;
ok(c.calls() === 4, 'one step per elision, per value, and one for done (got ' + c.calls() + ')');
eq(o.r, [2, 3], 'the counted iterator destructures correctly');

var c2 = counted(1);
o = {}; [, ...o.r] = c2;
ok(c2.calls() === 2, 'a rest that gets nothing still steps once for done (got ' + c2.calls() + ')');

// Declarations and plain variable targets keep working alongside.
var [, ...decl] = iter(3);
eq(decl, [2, 3], 'a let/var rest after an elision');
let [, ...letRest] = iter(2);
eq(letRest, [2], 'a let rest after an elision');

// A real array source takes a different iterator path; it must agree.
o = {}; [, ...o.r] = [1, 2, 3];
eq(o.r, [2, 3], 'array source, elision then member rest');
o = {}; [, ...o.r] = [1];
eq(o.r, [], 'array source, elision consumes the only value');
o = {}; [, ...o.r] = [];
eq(o.r, [], 'array source, empty');

// A string is iterable by code point.
o = {}; [, ...o.r] = 'abc';
eq(o.r, ['b', 'c'], 'string source');

if (fail === 0) {
    print('PASS: array rest into a member target (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
