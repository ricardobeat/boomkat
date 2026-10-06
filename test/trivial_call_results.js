function check(actual, expected, label) {
    if (!Object.is(actual, expected)) throw new Error(label);
}
function empty() {}
function identity(value) { return value; }
function third(a, b, c) { return c; }
function add(a, b) { return a + b; }
function swapped(a, b, c) { return c + a; }
var last = Function('a', 'a', 'return a;');
var arrow = value => value;
var holder = { identity: identity, add: add };
var rebound = identity;
var effects = 0;
function extra() { effects++; return 99; }
function withDefault(value = extra()) { return value; }
function withRest(...values) { return values.length; }
var kept = [];

// Repetition reaches the classified path; fresh results also exercise ownership
// when the caller overwrites registers and collection reclaims temporary values.
for (var i = 0; i < 1200; i++) {
    check(empty(extra()), undefined, 'empty and argument evaluation');
    check(identity(), undefined, 'missing parameter');
    check(third(1, 2), undefined, 'missing later parameter');
    check(third(1, 2, i, extra()), i, 'later and surplus parameters');
    check(last(1, i), i, 'duplicate sloppy parameters');
    check(arrow(i), i, 'arrow parameter');
    check(holder.add(i, 2), i + 2, 'method addition');
    check(swapped(i, 99, 2), i + 2, 'nonconsecutive operands');
    check(add(140737488355327, 1), 140737488355328, 'positive fastint overflow');
    check(add(-140737488355328, -1), -140737488355329, 'negative fastint overflow');
    check(add(1.5, 2), 3.5, 'Number plus fastint');
    check(add(2, 1.5), 3.5, 'fastint plus Number');
    check(add(-0, -0), -0, 'negative zero');
    check(add(-0, 0), 0, 'mixed zero');
    check(add(Infinity, -Infinity), NaN, 'nonfinite numbers');
    check(add(3), NaN, 'missing addition operand');
    check(add('value', i), 'value' + i, 'string conversion');
    check(add(2n, 3n), 5n, 'BigInt addition');
    check(withDefault(), 99, 'default effects');
    check(withRest(i, 2, 3), 3, 'rest initialization');

    var string = 'fresh-' + i + '-\uD83D\uDE00';
    var object = { i: i, string: string };
    check(holder.identity(object), object, 'method identity');
    check(identity(string), string, 'owned string');
    check(identity(identity), identity, 'function identity');
    var symbol = Symbol(string);
    check(identity(symbol), symbol, 'symbol identity');
    check(identity(12345678901234567890n), 12345678901234567890n, 'BigInt identity');
    if (i % 100 === 0) kept.push(identity(object));

    rebound = i % 2 ? identity : third;
    check(rebound(1, 2, i), i % 2 ? 1 : i, 'reassigned callee');
}
check(effects, 3600, 'all argument and default effects');
for (var i = 0; i < kept.length; i++) {
    check(kept[i].i, i * 100, 'retained object');
    check(kept[i].string, 'fresh-' + i * 100 + '-\uD83D\uDE00', 'retained string');
}

var order = '';
var left = { valueOf: function () { order += 'l'; return 4; } };
var right = { valueOf: function () { order += 'r'; return 5; } };
check(add(left, right), 9, 'user conversion');
check(order, 'lr', 'conversion order');
var thrown = { marker: 73 };
try {
    add({ valueOf: function () { throw thrown; } }, 1);
    throw new Error('conversion must throw');
} catch (error) { check(error, thrown, 'conversion exception'); }
check(add(3, 7), 10, 'call after exception');
print('trivial call results passed');
