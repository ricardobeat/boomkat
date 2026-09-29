function check(actual, expected, message) {
    if (actual !== expected) throw new Error(message + ': ' + actual + ' !== ' + expected);
}

function makeLabel(node, frame) {
    return node.name + ':' + frame;
}

var node = { name: 'node-12345' };
var retainedName = node.name;
var labels = [];
for (var i = 0; i < 128; i++) labels[i & 31] = makeLabel(node, i);
check(labels[0], 'node-12345:96', 'rotated label 0');
check(labels[31], 'node-12345:127', 'rotated label 31');
check(node.name, retainedName, 'source name remains unchanged');

var coercions = 0;
var converted = makeLabel(node, {
    [Symbol.toPrimitive]: function (hint) {
        check(hint, 'default', 'addition conversion hint');
        coercions++;
        return 'tail';
    }
});
check(converted, 'node-12345:tail', 'object suffix');
check(coercions, 1, 'suffix conversion count');

var threw = false;
try {
    makeLabel(node, Symbol('suffix'));
} catch (error) {
    threw = error instanceof TypeError;
}
check(threw, true, 'symbol suffix throws');
check(node.name, retainedName, 'source name survives throwing suffix');
check(makeLabel(node, 9), 'node-12345:9', 'concat after throwing suffix');
