var realm = $262.createRealm();
var foreign = realm.global;
var make = realm.evalScript(`
    let calls = 0;
    function make() {
        calls++;
        return { array: [calls], error: new TypeError(), boxed: Object(1n) };
    }
    make;
`);
for (var round = 0; round < 12; round++) {
    var values = [];
    for (var i = 0; i < 200; i++) values.push({ value: i, array: [i] });
    var value = make();
    assert.sameValue(Object.getPrototypeOf(value.array), foreign.Array.prototype);
    assert.sameValue(value.error instanceof foreign.TypeError, true);
    assert.sameValue(BigInt.prototype.valueOf.call(value.boxed), 1n);
    assert.sameValue(value.array[0], round + 1);
    assert.sameValue(Object.getPrototypeOf([]), Array.prototype);
}
var nested = realm.evalScript('$262.createRealm()');
assert.notSameValue(nested.global.Array, foreign.Array);
assert.sameValue(nested.evalScript('Object.getPrototypeOf([])'), nested.global.Array.prototype);
assert.sameValue(Object.getPrototypeOf(realm.evalScript('Promise.resolve()')), foreign.Promise.prototype);
