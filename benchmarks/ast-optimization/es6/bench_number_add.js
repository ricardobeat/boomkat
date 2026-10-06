function numberAdd(n) {
    let sum = 0.5;
    const step = 0.25;
    for (let i = 0; i < n; i++) sum += step;
    return sum;
}
const result = numberAdd(5000000);
if (result !== 1250000.5) throw new Error('wrong result');
print(result);
