function check(actual, expected, label) {
    if (!Object.is(actual, expected)) throw new Error(label + ': ' + actual);
}
function count(start, bound) {
    var i = start;
    var trips = 0;
    for (; i < bound; i++) {
        trips++;
        if (trips > 4) break;
    }
    return [i, trips];
}
function verify(start, bound, expected, trips, label) {
    var result = count(start, bound);
    check(result[0], expected, label + ' counter');
    check(result[1], trips, label + ' trips');
}
function changeBound() {
    var i = 0;
    var bound = 3;
    for (; i < bound; i++) bound = NaN;
    return i;
}
function changeCounter() {
    var i = 0.5;
    for (; i < 3; i++) i = NaN;
    return i;
}
function sameRegister(start) {
    var i = start;
    do { i++; } while (i < i);
    return i;
}
function decrement(start) {
    var i = start;
    i--;
    return i;
}
function singleIncrement(start) {
    var i = start;
    i++;
    return i;
}
for (var hot = 0; hot < 1200; hot++) {
    verify(0, 3, 3, 3, 'integer');
    verify(0, 3.25, 4, 4, 'double bound');
    verify(0.5, 3, 3.5, 3, 'double counter');
    verify(0.5, 3.25, 3.5, 3, 'double pair');
    verify(3, 3, 3, 0, 'zero trip');
    verify(-2, -0, 0, 2, 'negative bound');
    verify('1', 3, 3, 2, 'string counter');
    verify(0, '3', 3, 3, 'string bound');
    verify(0n, 3n, 3n, 3, 'BigInt');
    verify(0, 3n, 3, 3, 'BigInt bound');
    verify(0, NaN, 0, 0, 'NaN bound');
    verify(NaN, 3, NaN, 0, 'NaN counter');
    check(changeBound(), 1, 'bound changes after initial comparison');
    check(changeCounter(), NaN, 'counter changes after initial comparison');
    check(sameRegister(1), 2, 'same comparison register');
    check(sameRegister(0.5), 1.5, 'same double register');
    check(decrement(0.5), -0.5, 'double decrement');
    check(singleIncrement(0.5), 1.5, 'unpaired double increment');
}
verify(140737488355327, 140737488355328, 140737488355328, 1, 'fastint overflow');
verify(140737488355327, 140737488355328.5, 140737488355329, 2, 'overflow double bound');
verify(-140737488355328, -140737488355326, -140737488355326, 2, 'negative fastint');
verify(-Infinity, Infinity, -Infinity, 5, 'infinite counter');
check(singleIncrement(Infinity), Infinity, 'infinity increment');
check(decrement(-Infinity), -Infinity, 'infinity decrement');
check(singleIncrement(NaN), NaN, 'NaN increment');
check(decrement(NaN), NaN, 'NaN decrement');
check(singleIncrement(140737488355327), 140737488355328, 'unpaired fastint overflow');
check(decrement(-140737488355328), -140737488355329, 'fastint decrement overflow');
var order = '';
var start = { valueOf: function () { order += 'i'; return 1; } };
var bound = { valueOf: function () { order += 'b'; return 3; } };
verify(start, bound, 3, 2, 'object conversion');
check(order, 'ibibb', 'conversion order');
var calls = 0;
var marker = {};
try {
    count(0, { valueOf: function () { if (++calls === 2) throw marker; return 3; } });
    throw new Error('missing comparison throw');
} catch (e) { check(e, marker, 'comparison exception'); }
print('PASS: increment comparison');
