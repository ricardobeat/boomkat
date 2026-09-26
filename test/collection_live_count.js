function equal(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ': ' + actual + ' !== ' + expected);
}
function check(c, expected) {
    var n = 0;
    c.forEach(function () { n++; });
    equal(c.size, expected, 'size');
    equal(n, expected, 'iteration');
}
[0, 1, 7, 8, 16, 1024].forEach(function (n) {
    var m = new Map(), s = new Set();
    for (var i = 0; i < n; i++) { m.set(i, undefined); s.add(i); }
    check(m, n); check(s, n);
    for (var i = 0; i < n; i++) { m.set(i, i); s.add(i); }
    check(m, n); check(s, n);
    for (var i = 0; i < n; i += 2) { m.delete(i); s.delete(i); }
    check(m, Math.floor(n / 2)); check(s, Math.floor(n / 2));
    m.delete(-1); s.delete(-1);
    for (var i = 0; i < n; i += 2) { m.set(i, i); s.add(i); }
    check(m, n); check(s, n);
    m.clear(); s.clear(); check(m, 0); check(s, 0);
    m.set(undefined, undefined); s.add(undefined); check(m, 1); check(s, 1);
    m.set(NaN, 1); m.set(NaN, 2); s.add(NaN); s.add(NaN);
    m.set(-0, 1); m.set(0, 2); s.add(-0); s.add(0);
    check(m, 3); check(s, 3);
});
var a = new Set([1, 2, 3]), b = new Set([3, 4]);
if (typeof a.union === 'function') {
    check(a.union(b), 4); check(a.intersection(b), 1);
    check(a.difference(b), 2); check(b.difference(a), 1);
    check(a.symmetricDifference(b), 3);
    var other = {size: 0, has: function () { return false; }, keys: function () { return [2, 2][Symbol.iterator](); }};
    check(a.difference(other), 2);
    check(a.symmetricDifference(other), 2);
    check(a.union(other), 3);
}
if (typeof Map.groupBy === 'function') {
    var grouped = Map.groupBy([1, 2, 3, 4], function (v) { return v % 2; });
    check(grouped, 2); grouped.delete(0); check(grouped, 1);
}
var m = new Map();
if (typeof m.getOrInsert === 'function') {
    m.getOrInsert('a', undefined); m.getOrInsert('a', 2); check(m, 1);
    m.getOrInsertComputed('b', function (key) { m.set(key, 4); return 5; });
    check(m, 2); equal(m.get('b'), 5, 'computed overwrite');
    m.getOrInsertComputed('c', function () { m.clear(); return 6; }); check(m, 1);
    try { m.getOrInsertComputed('d', function () { throw new Error('stop'); }); } catch (e) {}
    check(m, 1);
}
var s = new Set([1, 2]), it = s.values();
equal(it.next().value, 1, 'first'); s.delete(2); s.add(3);
equal(it.next().value, 3, 'live iterator'); check(s, 2);
var visited = 0;
s.forEach(function (v) { visited++; if (v === 1) { s.delete(3); s.add(4); } });
equal(visited, 2, 'mutation during foreach'); check(s, 2);
var key = {}, value = {label: 'retained'};
var ownedMap = new Map([[key, value]]), ownedSet = new Set([key]);
ownedMap.note = value; ownedSet.note = value;
check(ownedMap, 1); check(ownedSet, 1);
equal(ownedMap.get(key), value, 'object key');
equal(ownedMap.note, value, 'map named property');
equal(ownedSet.note, value, 'set named property');
ownedMap.delete(key); ownedSet.delete(key);
check(ownedMap, 0); check(ownedSet, 0);
print('collection_live_count: passed');
