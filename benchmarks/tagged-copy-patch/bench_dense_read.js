function run(items, n) { let value = ''; for (let i = 0; i < n; i++) value = items[i]; return value; }
const items = [];
for (let i = 0; i < 1000000; i++) items.push(i & 1 ? 'selected' : 'ignored');
let result;
for (let i = 0; i < 3; i++) result = run(items, items.length);
if (result !== 'selected') throw new Error('array');
console.log(result);
