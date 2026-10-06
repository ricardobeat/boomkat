function run(n, a, b) {
    let value = a;
    const peek = () => value;
    const choose = (flag, fallback) => flag ? value : fallback;
    for (let i = 0; i < n; i++) { value = choose(i & 1, b); }
    return peek();
}
const object = {label:'object'};
if (run(3000000, 'string', object) !== object) throw new Error('capture mismatch');
console.log('captured selection OK');
