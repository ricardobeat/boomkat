function manyBlocks(x, a, b, c, d, e) {
    if (a) x = x + 1;
    if (b) x = x + 2;
    if (c) x = x + 4;
    if (d) x = x + 8;
    if (e) x = x + 16;
    return x * 2;
}
function driveBlocks(x, a, b, c, d, e) { return manyBlocks(x, a, b, c, d, e) + 1; }
for (var j = 0; j < 5000; j++) {
    var a = (j & 1) !== 0, b = (j & 2) !== 0, c = (j & 4) !== 0;
    var d = (j & 8) !== 0, e = (j & 16) !== 0;
    var got = driveBlocks(j, a, b, c, d, e);
    var expected = (j + (a ? 1 : 0) + (b ? 2 : 0) + (c ? 4 : 0) + (d ? 8 : 0) + (e ? 16 : 0)) * 2 + 1;
    if (got !== expected) throw Error('many blocks');
}
var coercions = 0;
var input = { valueOf: function () { coercions++; return 5; } };
if (driveBlocks(input, true, false, true, false, true) !== 53 || coercions !== 1)
    throw Error('many-block coercion recovery');
var savedManyBlocks = manyBlocks;
manyBlocks = function () { coercions++; return 41; };
if (driveBlocks(5, true, false, true, false, true) !== 42 || coercions !== 2)
    throw Error('many-block call mutation');
manyBlocks = savedManyBlocks;
console.log('many blocks: PASS');
