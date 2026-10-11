function equal(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' !== ' + expected);
}

// One bytecode site alternates between fresh captured environments.
function makeReader(value) {
    const captured = value;
    return function () {
        const local = 3;
        return captured + local;
    };
}
var readers = [];
for (var i = 0; i < 30; i++) readers.push(makeReader(i));
for (var round = 0; round < 4; round++) {
    for (var i = 0; i < readers.length; i++) equal(readers[i](), i + 3);
}

// Fresh intermediate scopes share an owner, but eval can introduce a shadow.
function makeEvalReader() {
    var value = 19;
    return function (shadow) {
        var initial = value;
        if (shadow) eval('var value = 41');
        return initial + value;
    };
}
var evalReader = makeEvalReader();
for (var i = 0; i < 20; i++) equal(evalReader(false), 38);
equal(evalReader(true), 60);
equal(evalReader(false), 38);

function withReader(object) {
    var value = 7;
    with (object) { return value; }
}
for (var i = 0; i < 10; i++) {
    equal(withReader({value: i}), i);
    equal(withReader({}), 7);
}

// A descriptor change on one object must leave its shape peers intact.
function pair() { return {left: 1, right: 2}; }
var first = pair(), second = pair();
Object.defineProperty(first, 'left', {writable: false, enumerable: false});
equal(Object.keys(first).join(','), 'right');
equal(Object.keys(second).join(','), 'left,right');
second.left = 5;
equal(second.left, 5);
first.left = 9;
equal(first.left, 1);
Object.defineProperty(first, 'right', {get: function () { return 13; }});
equal(first.right, 13);
equal(second.right, 2);

// Replaying flags preserves indexed key ordering and symbol keys.
var symbol = Symbol('field');
function keyed() { return {'10': 10, '2': 2, tail: 3, [symbol]: 4}; }
var keyedFirst = keyed(), keyedSecond = keyed();
Object.defineProperty(keyedFirst, 'tail', {enumerable: false});
equal(Object.keys(keyedFirst).join(','), '2,10');
equal(Object.keys(keyedSecond).join(','), '2,10,tail');
equal(keyedFirst[symbol], 4);
equal(keyedSecond[symbol], 4);
print('var_ic_rearm: PASS');
