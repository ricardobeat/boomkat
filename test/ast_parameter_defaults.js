function same(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(String(actual) + ' !== ' + String(expected));
}
function referenceError(fn) {
    var caught = false;
    try { fn(); } catch (e) { caught = e instanceof ReferenceError; }
    same(caught, true);
}
function simple(a, b = a + 1, c = b * 2) { return c; }
same(simple.length, 1);
same(simple(3), 8);
same(simple(3, undefined), 8);
same(simple(3, 5), 10);
same(simple(3, null), 0);
same(simple(3, 0), 0);
same(simple(3, 5, 7), 7);
same(simple('3'), 62);
same(simple(NaN), NaN);
function literals(a = -0, b = 'x', c = true, d = null) {
    same(a, -0); same(b, 'x'); same(c, true); same(d, null);
}
literals();
var coercions = 0;
same(simple({ valueOf: function () { coercions++; return 3; } }), 8);
same(coercions, 1);
var marker = {};
try { simple({ valueOf: function () { throw marker; } }); throw new Error('missing throw'); }
catch (e) { same(e, marker); }
referenceError(function () { return (function (a = b + 1, b = 2) {} )(); });
referenceError(function () { return (function (a = a + 1) {} )(); });
function mutation(a, b = (a = 4), c = a + 1) { return c; }
same(mutation(2), 5);
function captures(a = 1, read = () => a, b = a + 1) {
    var a = 4;
    return read() + b;
}
same(captures(), 3);
function unmapped(a, b = a + 1) { arguments[0] = 9; return a + b; }
same(unmapped(2), 5);
function evalDefault(a, b = eval('a + 1'), c = a + b) { return c; }
same(evalDefault(2), 5);
function patterns(a, b = a + 1, [c] = [b]) { return c; }
same(patterns(2), 3);
function rest(a, b = a + 1, ...args) { return b + args.length; }
same(rest(2), 3);
same(rest(2, undefined, 8, 9), 5);
same(((a, b = a + 1) => b)(2), 3);
function* generator(a, b = a + 1) { yield b; }
same(generator(2).next().value, 3);
function Target(a, b = a + 1, target = new.target) { this.value = b; this.target = target; }
var instance = new Target(2);
same(instance.value, 3);
same(instance.target, Target);
(function () {
    'use strict';
    function strict(a, b = a + 1) { return b; }
    same(strict(2), 3);
})();
