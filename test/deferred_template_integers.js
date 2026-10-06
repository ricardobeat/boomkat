function same(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' != ' + expected);
}
function format(n) { return `[${n}:${n + 1}]`; }
function mutate(n) { return `${n}:${n = 99}:${n}`; }
function later(n) {
    function change() { n = 7; return n; }
    return `${n}:${change()}:${n}`;
}
for (var round = 0; round < 1200; round++) {
    var n = round - 600;
    same(format(n), '[' + String(n) + ':' + String(n + 1) + ']');
    same(mutate(n), String(n) + ':99:99');
    same(later(n), String(n) + ':7:7');
}
for (var n of [0, 9, 10, 99, 100, -1, -10, 140737488355327, -140737488355328]) {
    same(format(n), '[' + String(n) + ':' + String(n + 1) + ']');
}
same(`head ${-0} tail ${1.5}`, 'head 0 tail 1.5');
same(`head ${1n} tail ${NaN}`, 'head 1 tail NaN');
same(`α${17}🙂${-29}β`, 'α17🙂-29β');
var marker = {};
try {
    `${17}${{ toString: function () { throw marker; } }}`;
    throw new Error('missing conversion throw');
} catch (e) { same(e, marker); }
var events = [];
function failInCallee() {
    return `${17}${{ toString: function () { events.push('convert'); throw marker; } }}`;
}
try {
    try { failInCallee(); }
    finally { events.push('finally'); }
} catch (e) { same(e, marker); events.push('caught'); }
same(events.join(','), 'convert,finally,caught');
var held = [];
for (var i = 0; i < 500; i++) held.push(`entry ${i} tail`);
for (var i = 0; i < 500; i++) same(held[i], 'entry ' + i + ' tail');
function* suspended(n) { return `${n}:${yield 'pause'}:${n}`; }
var iterator = suspended(3);
same(iterator.next().value, 'pause');
same(iterator.next('resume').value, '3:resume:3');
async function awaited(n) { return `${n}:${await (n = 7)}:${n}`; }
awaited(3).then(function (result) {
    same(result, '3:7:7');
    print('PASS: deferred template integers');
});
