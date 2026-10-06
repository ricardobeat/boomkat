function numeric(a, b, c) { return (a + b) * c - a; }
function bench(n) {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += numeric(i, 3, 2);
    return sum;
}
const result = bench(3000000);
if (result !== 4500016500000) throw new Error('numeric call result: ' + result);
print(result);
