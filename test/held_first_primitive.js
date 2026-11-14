// A binary operator converts both operands before it reads either result, so
// the first operand's fresh primitive must outlive the second conversion.
function assert(ok, what) { if (!ok) throw new Error('FAIL: ' + what); }
var fresh = (v) => ({ valueOf() { return v(); }, toString() { return v(); } });
var s = fresh(() => ['a', 'b'].join('-') + '!');
var big = fresh(() => 2n ** 70n + 1n);
for (var i = 0; i < 50; i++) {
    assert([1, 2] + [3, 4] === '1,23,4', 'array + array');
    assert(s + s === 'a-b!a-b!', 'string results of user conversions');
    assert(!([1, 2] < [1, 2]) && [1, 2] < [1, 3] && s <= s, 'relational string results');
    assert(big + big === 2n ** 71n + 2n, 'bigint + bigint');
    assert(!(big < big) && big <= big, 'bigint relational');
    assert(s + big === 'a-b!1180591620717411303425', 'string + bigint');
}
print('held first primitive: OK');
