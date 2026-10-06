function check(actual, expected, label) {
    if (!Object.is(actual, expected)) throw new Error(label);
}
function left(a, b, c) { return a + b + c; }
function right(a, b, c) { return c + (a + b); }
function double(a, b) { var sum = a + b; return sum + sum; }
function assign(a, b, c) { var sum = a + b; sum = sum + c; return sum; }
function pairs(a, b, c, d) { var x = a + b; var y = c + d; return x + y; }
function restLength(a, b, ...rest) { return rest.length + a + b; }

for (var i = 0; i < 1500; i++) {
    check(left(i, 2, 3), i + 5, 'left operand chain');
    check(right(i, 2, 3), i + 5, 'right operand chain');
    check(double(i, 2), (i + 2) * 2, 'repeated intermediate');
    check(assign(i, 2, 3), i + 5, 'overwritten intermediate');
    check(pairs(i, 2, 3, 4), i + 9, 'independent sums');
    check(restLength(2, 3, i, 99), 7, 'rest count still elided');
}
check(left(140737488355327, 1, -1), 140737488355327, 'first fastint overflow');
check(left(140737488355326, 1, 1), 140737488355328, 'second fastint overflow');
check(left(-140737488355328, -1, 1), -140737488355328, 'negative overflow');
check(left(1.5, 2, 3), 6.5, 'first Number operand');
check(left(1, 2, 3.5), 6.5, 'second Number operand');
check(left(-0, -0, -0), -0, 'negative zero');
check(left(Infinity, -Infinity, 3), NaN, 'nonfinite numbers');
check(left('a', 'b', 'c'), 'abc', 'string chain');
check(right('a', 'b', 'c'), 'cab', 'right string order');
check(left(1, 2, '3'), '33', 'numeric then string');
check(right(1, 2, '3'), '33', 'string then numeric result');
check(left(2n, 3n, 4n), 9n, 'BigInt chain');

var order = '';
function object(tag, value) {
    return { valueOf: function () { order += tag; return value; } };
}
check(left(object('a', 1), object('b', 2), object('c', 3)), 6, 'left conversion');
check(order, 'abc', 'left conversion order');
order = '';
check(right(object('a', 1), object('b', 2), object('c', 3)), 6, 'right conversion');
check(order, 'abc', 'inner sum precedes outer conversion');
order = '';
var error = { marker: 71 };
try {
    left(object('a', 1), object('b', 2), {
        valueOf: function () { order += 'c'; throw error; }
    });
    throw new Error('must throw');
} catch (caught) { check(caught, error, 'second conversion exception'); }
check(order, 'abc', 'conversion effects occur once');

var caught = false;
try { left(1, 2, Symbol('sum')); } catch (error) { caught = error instanceof TypeError; }
check(caught, true, 'second addition rejects symbol');
check(left(1, 2, 3), 6, 'call after exception');

function replaceStrings(a, b, c) {
    var temporary = 'owned-' + a + '-suffix';
    var result = temporary;
    for (var step = 0; step < 2; step++) {
        if (step === 0) check(result, temporary, 'two string owners');
        else check(result, a + b + c, 'retained result');
        temporary = a + b;
        result = temporary + c;
    }
    check(temporary, a + b, 'intermediate survives final store');
    return result;
}
for (var i = 0; i < 1500; i++) check(replaceStrings(i, 2, 3), i + 5, 'shared destination ownership');
print('fused addition results passed');
