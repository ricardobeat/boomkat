function assert(condition, message) {
    if (!condition) throw new Error(message);
}

var m = /(a)?(?<word>b)/d.exec('b');
assert(m !== null, 'match exists');
assert(m.length === 3, 'capture count is reflected in length');
assert(m[0] === 'b' && m[1] === undefined && m[2] === 'b', 'capture values');
assert(0 in m && 1 in m && 2 in m, 'unmatched capture remains present');
assert(m.index === 0 && m.input === 'b', 'index and input properties');
assert(m.groups.word === 'b', 'named group result');
assert(m.indices[0][0] === 0 && m.indices[0][1] === 1, 'full-match indices');
assert(m.indices[1] === undefined, 'unmatched capture indices');
assert(m.indices[2][0] === 0 && m.indices[2][1] === 1, 'capture indices');
assert(m.indices.groups.word[0] === 0 && m.indices.groups.word[1] === 1,
    'named capture indices');

var noNames = /(x)?b/.exec('b');
assert(noNames !== null && 1 in noNames && noNames[1] === undefined,
    'unmatched numeric capture is an own indexed property');

var descriptor = Object.getOwnPropertyDescriptor(noNames, '1');
assert(descriptor !== undefined && descriptor.value === undefined
    && descriptor.writable && descriptor.enumerable && descriptor.configurable,
    'unmatched capture retains its data-property descriptor');

print('regexp match-result storage: ok');
