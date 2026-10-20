// A throwing Proxy `get` trap for "prototype" on newTarget propagates out of
// builtin constructors that read it before validating their arguments.
var poison = new Proxy(function () {}, {
    get: function (t, k) { if (k === 'prototype') throw new RangeError('poison'); return t[k]; }
});
function check(C, args) {
    try { Reflect.construct(C, args, poison); } catch (e) {
        if (!(e instanceof RangeError) || e.message !== 'poison') throw new Error(C.name + ' lost the trap error: ' + e);
        return;
    }
    throw new Error(C.name + ' did not read newTarget.prototype');
}
check(Intl.Locale, []);
check(Intl.DisplayNames, []);
check(Map, []);
print('ok');
