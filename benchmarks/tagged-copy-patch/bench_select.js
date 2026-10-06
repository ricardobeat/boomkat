function choose(flag, a, b) { return flag ? a : b; }
function run(n, a, b) {
    let result = a;
    for (let i = 0; i < n; i++) { result = choose(i & 1, a, b); }
    return result;
}
const object = {label:'object'};
if (run(3000000, 'string', object) !== 'string') throw new Error('selection mismatch');
console.log('selection OK');
