function first(a, b) { return [a, b][0]; }
function run(n, a, b) { let value = b; for (let i = 0; i < n; i++) value = first(a, b); return value; }
const result = run(3000000, 'selected', {name: 'other'});
if (result !== 'selected') throw new Error('projection');
console.log(result);
