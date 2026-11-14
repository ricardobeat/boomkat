// apply's argument slots are the calling frame's: each argument must arrive owned, and all of
// them referenced before the slot holding the argument array is released.
var fail = 0;
function check(cond, msg) { if (!cond) { fail++; print('FAIL: ' + msg); } }

// A lightfunc target with a string argument held by a constant.
var probe = { tag: 'probe' };
var hasOwn = Object.prototype.hasOwnProperty;
for (var i = 0; i < 40; i++) check(Reflect.apply(hasOwn, probe, ['tag']) === true, 'Reflect.apply lightfunc ' + i);
for (var i = 0; i < 40; i++) check(hasOwn.apply(probe, ['tag']) === true, 'apply lightfunc ' + i);
check(probe.tag === 'probe', 'receiver intact');

// Arguments owned only by a literal array longer than the slots before it.
function last(a, b, c, d, e) { return e.name + d.name + c.name; }
for (var i = 0; i < 40; i++) {
    check(Reflect.apply(last, null, [1, 2, { name: 'c' }, { name: 'd' }, { name: 'e' + i }]) === 'e' + i + 'dc', 'Reflect.apply fresh args ' + i);
    check(last.apply(null, [1, 2, { name: 'c' }, { name: 'd' }, { name: 'e' + i }]) === 'e' + i + 'dc', 'apply fresh args ' + i);
}
var concat = Array.prototype.concat;
for (var i = 0; i < 40; i++) {
    var out = Reflect.apply(concat, [i], [['a' + i], ['b' + i], ['c' + i], ['d' + i]]);
    check(out.join() === i + ',a' + i + ',b' + i + ',c' + i + ',d' + i, 'Reflect.apply builtin fresh args ' + i);
    out = Math.max.apply(null, [i, i + 0.5, i - 1, { valueOf: function () { return 1e6; } }]);
    check(out === 1e6, 'apply lightfunc fresh args ' + i);
}
print(fail === 0 ? 'apply_argument_ownership: ok' : 'SOME TESTS FAILED');
if (fail > 0) throw new Error('FAIL');
