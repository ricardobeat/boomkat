// An append to a shared shape: the object counts the new property before the transition that
// names it, so a lookup made between the two runs against a shape whose key list is one short.
// The shared shape's hash table is sized for that shorter list, and every probe must stay inside
// it. ASan reports the read past the table when it does not.
var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print('FAIL: ' + m); } }

// Eleven named properties take an array's shape past HASH_MIN_PROPS, and a second array from the
// same builder makes the shape shared, so its lookups probe the one hash table the shape owns.
function mk() {
  var a = [];
  for (var i = 0; i < 11; i++) a['p' + i] = i;
  return a;
}
var x = mk(), y = mk();
// The read of an existing key builds the shape's table at its eleven-key size.
assert(y.p0 === 0, 'shared shape read');
assert(x.p10 === 10, 'second reader on the shared shape');

// An explicit undefined cannot sit in a dense slot, so it enters the named table: the append path
// that reaches the probe with the object's count already one past the shape's.
x.push(undefined);
assert(x.length === 1, 'append past the shared shape');
assert(x[0] === undefined, 'appended value');
assert(Object.keys(x).length === 12, 'named keys after the append');
assert(y.p7 === 7 && y.length === 0, 'the other instance of the shape');

// Past the boundary where the probe's mask would grow with the object's count: eleven keys fit a
// sixteen-slot table, and the next append must not probe a thirty-two-slot one.
var big = mk();
big.q = 1;
big.push(undefined);
big.push(undefined);
assert(big.length === 2, 'two appends past the shared shape');
assert(big.q === 1 && big.p9 === 9, 'keys survive the second append');
assert(x.length === 1, 'first array unchanged');

print('shape_hash_append_probe: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
