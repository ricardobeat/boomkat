function field(item) { return item.name; }
function run(item, n) { let value = ''; for (let i = 0; i < n; i++) value = field(item); return value; }
const result = run({name: 'selected'}, 3000000);
if (result !== 'selected') throw new Error('property');
console.log(result);
