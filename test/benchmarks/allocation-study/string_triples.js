function join(a, b, c) { return a + b + c; }
var fragments = [];
for (var i = 0; i < 257; i++) fragments.push('fragment-' + i + '-'.repeat(64));
var checksum = 0;
for (var i = 0; i < 1200000; i++) {
    var text = join(fragments[i % 257], fragments[(i + 1) % 257], fragments[(i + 2) % 257]);
    checksum += text.length;
}
if (join('a', 'b', 'c') !== 'abc' || join(1, 2, 'x') !== '3x')
    throw new Error('join result');
var effects = '';
var first = { toString: function () { effects += 'a'; return 'a'; } };
var last = { toString: function () { effects += 'c'; return 'c'; } };
if (join(first, 'b', last) !== 'abc' || effects !== 'ac')
    throw new Error('coercion order');
print('PASS ' + checksum);
