function same(actual, expected) {
    if (actual !== expected) throw new Error(actual + ' != ' + expected);
}
function format(value) { return `${value}`; }
for (const n of [0, 1, 9, 10, 99, 100, -1, -9, -10,
                 140737488355327, -140737488355328]) {
    same(format(n), String(n));
    same(`prefix ${n} suffix`, 'prefix ' + String(n) + ' suffix');
}
same(`${-0}`, '0');
same(`${1.5} ${true} ${null} ${undefined}`, '1.5 true null undefined');
same(`${12345678901234567890n}`, '12345678901234567890');
same(`${''}`, '');
same(`a${'\0'}b`.length, 3);
same(`α${'🙂'}β`.length, 4);
same(`α${'🙂'}β`.charAt(3), 'β');
const chunk = 'λ'.repeat(400);
same(`head${chunk}${17}tail`, 'head' + chunk + '17tail');

const array = [];
array[`${4}${2}`] = 'index';
same(array.length, 43);
same(array[42], 'index');
const object = {};
object[`key${17}`] = 8;
same(object.key17, 8);

const order = [];
const a = {toString() { order.push('a'); return 'A'; }};
function b() { order.push('b'); return {toString() { order.push('B'); return 'B'; }}; }
same(`${a}${b()}`, 'AB');
same(order.join(','), 'a,b,B');
let threw = false;
try { `${Symbol('join')}`; } catch (e) { threw = e instanceof TypeError; }
same(threw, true);

const kept = [];
for (let i = 0; i < 500; i++) kept.push(`item${i}:${'λ'.repeat(8)}`);
for (let i = 0; i < 500; i++) {
    same(kept[i], 'item' + i + ':' + 'λ'.repeat(8));
    same(kept[i].length, String(i).length + 13);
}
