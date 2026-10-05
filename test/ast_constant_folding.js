function same(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error(String(actual) + ' !== ' + String(expected));
}
same((2 + 3) * 4, 20);
same(0.1 + 0.2, 0.30000000000000004);
same((1e16 + -1e16) + 1, 1);
same(1e16 + (-1e16 + 1), 0);
same(-0, -0);
same(0 * -1, -0);
same(-4 % 2, -0);
same(-0 + -0, -0);
same(-0 + 0, 0);
same(1 / -0, -Infinity);
same(1 / 0, Infinity);
same(0 / 0, NaN);
same(1 % 0, NaN);
same(1e308 * 1e308, Infinity);
same(5e-324 / 2, 0);
same(-5e-324 / 2, -0);
same((0 / 0) === (0 / 0), false);
same((0 / 0) !== 1, true);
same((0 / 0) < 1, false);
same((0 / 0) >= 1, false);
same(-0 === 0, true);
same(3 <= 3, true);
same(4 > 3, true);
same(3 == 3, true);
same(3 != 3, false);
same(!(0 / 0), true);
same(!-0, true);
same(!3, false);
same(+(2 + 3), 5);

var effects = 0;
var object = { valueOf: function () { effects++; return 3; } };
same((2 + 3) + object, 8);
same(effects, 1);
same('2' + 3, '23');
same(2n + 3n, 5n);
var threw = false;
try { 1n + 2; } catch (e) { threw = e instanceof TypeError; }
same(threw, true);
same(Function('"use " + "strict"; return this')(), globalThis);
same(Function('return ' + Array(20000).fill('1').join('+'))(), 20000);
same(Function('return ' + Array(80).fill('1').join('+'))(), 80);
var fn = function () { return (2 + 3) * 4; };
same(fn.toString().indexOf('(2 + 3) * 4') >= 0, true);
