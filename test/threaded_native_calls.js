// Builtin calls from the threaded loop.
//
// A CALL or TAILCALL_CALL whose callee is a native builtin used to bail to
// the switch. The threaded loop now runs the builtin itself. A throw cannot
// re-run the call, so it is raised at the next instruction by vm_dispatch;
// the builtins that re-dispatch the call (call, apply, eval, generator
// resume) still go to the switch. String `length` is read in the loop too.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

// A scanner: method calls, tail calls and length on a string primitive.
function codeAt(s, i) { return s.charCodeAt(i); }
function scan(text) {
    var sum = 0;
    for (var i = 0; i < text.length; i++) sum += codeAt(text, i) + text.indexOf('z', i);
    return sum;
}
var text = 'abcxyz-';
var want = 0;
for (var i = 0; i < text.length; i++) want += text.charCodeAt(i) + text.indexOf('z', i);
for (var r = 0; r < 200; r++) eq(scan(text), want, 'scan round ' + r);
eq('héllo'.length, 5, 'non-ASCII string length');

// A builtin that throws inside a hot loop is caught where the call stands.
function parseAll(list) {
    var bad = 0, last = null;
    for (var i = 0; i < list.length; i++) {
        try { last = JSON.parse(list[i]); }
        catch (e) { bad++; eq(e instanceof SyntaxError, true, 'SyntaxError ' + i); }
    }
    return bad + ':' + last;
}
for (var r = 0; r < 50; r++) eq(parseAll(['1', '{', '2', ']', '3']), '2:3', 'parse round ' + r);

// A throw from a tail-called builtin propagates to the caller's handler.
function tailThrow(o) { return o.toFixed(200); }
var caught = 0;
for (var r = 0; r < 100; r++) {
    try { tailThrow(1.5); } catch (e) { if (e instanceof RangeError) caught++; }
}
eq(caught, 100, 'tail-called builtin throw');

// An uncaught throw from a builtin in a callee unwinds through its frame.
function inner(x) { return x.toFixed(-1); }
function outer(x) { var r = inner(x); return 'unreached' + r; }
var msg = '';
try { for (var r = 0; r < 100; r++) outer(r); } catch (e) { msg = e.name; }
eq(msg, 'RangeError', 'throw through a frame');

// A builtin whose callback recurses deeply can move the value stack; the
// caller's registers must be re-read after it returns.
function depth(n) { return n == 0 ? 0 : 1 + depth(n - 1); }
var keep = { tag: 'kept' };
for (var r = 0; r < 20; r++) {
    var before = keep;
    eq([2000 + r].map(depth)[0], 2000 + r, 'deep callback ' + r);
    eq(before.tag, 'kept', 'register survives a stack move');
}

// Re-dispatching builtins still work at hot sites.
function add(a, b) { return this.base + a + b; }
var ctx = { base: 10 }, t = 0;
for (var r = 0; r < 200; r++) t += add.call(ctx, 1, 2) + add.apply(ctx, [3, 4]) + Reflect.apply(add, ctx, [0, 0]);
eq(t, 200 * (13 + 17 + 10), 'call, apply and Reflect.apply');
function* gen() { var x = yield 1; yield x * 2; }
var g = gen(), seq = [];
seq.push(g.next().value, g.next(21).value, g.next().done);
eq(seq.join(), '1,42,true', 'generator resume');

print('threaded_native_calls: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
