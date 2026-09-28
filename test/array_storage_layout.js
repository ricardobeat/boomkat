function check(v, label) { if (!v) throw new Error(label); }
for (var round = 0; round < 40; round++) {
    var a = [1, 'two', {n: 3}];
    for (var i = 0; i < 24; i++) a['p' + i] = 'value-' + i;
    for (var i = 3; i < 200; i++) a.push(i);
    check(a[1] === 'two' && a[2].n === 3 && a[199] === 199, 'dense after named growth');
    for (var i = 0; i < 24; i++) check(a['p' + i] === 'value-' + i, 'named after dense growth');
    delete a.p3;
    Object.defineProperty(a, 'named', {get: function() {return this[1];}, configurable: true});
    check(a.named === 'two', 'accessor');
    a.length = 2;
    check(a[2] === undefined && a.p23 === 'value-23', 'truncate preserves names');
    a[300] = 'far';
    check(!(299 in a) && a[300] === 'far' && a.length === 301, 'holes');
    Object.freeze(a);
    check(a[300] === 'far' && Object.isFrozen(a), 'freeze');
    var empty = [];
    empty.name = 'empty';
    empty.push('element');
    check(empty.name === 'empty' && empty[0] === 'element', 'named first');
}
(function(a, b) {
    arguments.extra = 'named';
    a = 'mapped';
    check(arguments[0] === 'mapped' && arguments.extra === 'named', 'arguments layout');
})('first', 'second');
var map = new Map([[1, 'one']]);
var set = new Set(['one']);
check(map.get(1) === 'one' && set.has('one'), 'collection layout');
print('array storage PASS');
