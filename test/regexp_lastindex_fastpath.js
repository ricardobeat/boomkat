function assert(condition, message) {
    if (!condition) throw new Error(message);
}

var reentrant = /x/g;
var coercionValue = {
    valueOf: function () {
        Object.defineProperty(reentrant, 'lastIndex', { writable: false });
        return 0;
    }
};
Object.defineProperty(reentrant, 'lastIndex', {
    value: coercionValue,
    writable: true
});
var threw = false;
try {
    reentrant.exec('x');
} catch (e) {
    threw = e instanceof TypeError;
}
assert(threw, 'write after lastIndex coercion observes non-writable descriptor');

var stringIndex = /x/g;
stringIndex.lastIndex = '0';
var stringMatch = stringIndex.exec('x');
assert(stringMatch !== null && stringMatch.index === 0 && stringIndex.lastIndex === 1,
    'string lastIndex keeps ToLength conversion');

var negativeIndex = /x/g;
negativeIndex.lastIndex = -1;
var negativeMatch = negativeIndex.exec('x');
assert(negativeMatch !== null && negativeMatch.index === 0 && negativeIndex.lastIndex === 1,
    'negative lastIndex clamps to zero');

print('regexp lastIndex fast path: ok');
