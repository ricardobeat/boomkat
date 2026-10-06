function pick(item, fallback) { const active = item.active; const name = item.name; return active ? name : fallback; }
function run(items, n) { let value = ''; for (let i = 0; i < n; i++) value = pick(items[i], value); return value; }
const items = [];
const a = {active: true, name: 'selected'}, b = {active: false, name: 'ignored'};
for (let i = 0; i < 1000000; i++) items.push(i & 1 ? a : b);
let result;
for (let i = 0; i < 3; i++) result = run(items, items.length);
if (result !== 'selected') throw new Error('selection');
console.log(result);
