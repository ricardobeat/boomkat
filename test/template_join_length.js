function same(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' != ' + expected);
}
function length(a, b) {
    const text = `α${a}🙂${b}β`;
    return text.length;
}
function snapshot(n) {
    const text = `${n}:${n = 99}:${n}`;
    return text.length;
}
function direct(n) { return `entry ${n} tail`.length; }
function reused(n) {
    let text = `one ${n}`;
    const first = text.length;
    text = `two ${n}`;
    return first + text.length;
}
function overwritten(n) {
    let value = { retained: 'initial' };
    for (let i = 0; i < n; i++) {
        const text = `entry ${i} tail`;
        value = text.length;
    }
    return value;
}
function escaped(n) {
    const text = `entry ${n} tail`;
    const count = text.length;
    return [text, count];
}
function branch(n, keep) {
    const text = `entry ${n} tail`;
    const count = text.length;
    if (keep) return text;
    return count;
}
function captured(n) {
    const text = `entry ${n} tail`;
    const count = text.length;
    return [count, function () { return text; }];
}
function evaluated(n) {
    const text = `entry ${n} tail`;
    const count = text.length;
    return [count, eval('text')];
}
for (var i = 0; i < 1500; i++) {
    var n = i - 750;
    same(length(n, i), ('α' + String(n) + '🙂' + String(i) + 'β').length);
    same(snapshot(n), (String(n) + ':99:99').length);
    var pair = escaped(n);
    same(pair[0], 'entry ' + n + ' tail');
    same(pair[1], pair[0].length);
}
for (var value of [0, -0, 1.5, NaN, Infinity, -1, 140737488355327,
                  -140737488355328, 1n, null, undefined, true, 'é', '🙂', '\ud800', '\udc00']) {
    same(length(value, ''), ('α' + String(value) + '🙂β').length);
}
same(length('\ud800', '\udc00'), 6);
same(direct(7), 12);
same(reused(3), 10);
same(overwritten(1500), 15);
same(branch(7, true), 'entry 7 tail');
same(branch(7, false), 12);
var closure = captured(7);
same(closure[0], 12);
same(closure[1](), 'entry 7 tail');
same(evaluated(7).join(','), '12,entry 7 tail');
var conversions = 0;
same(length(17, { toString: function () { conversions++; return '界🙂'; } }), 9);
same(conversions, 1);
var marker = {};
try {
    length(17, { toString: function () { throw marker; } });
    throw new Error('missing conversion throw');
} catch (e) { same(e, marker); }
try {
    length(17, Symbol('stop'));
    throw new Error('missing Symbol throw');
} catch (e) { same(e instanceof TypeError, true); }
function caught(value) {
    try { const text = `${17}:${value}`; return text.length; }
    catch (e) { return e; }
}
same(caught({ toString: function () { throw marker; } }), marker);
var longText = '界🙂'.repeat(1024);
same(length(longText, longText), 6148);
print('PASS: template join length');
