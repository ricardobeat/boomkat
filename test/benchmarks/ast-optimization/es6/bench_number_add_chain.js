function numberChain(n) {
    let sum = 0.5;
    const a = 0.125;
    const b = 0.375;
    for (let i = 0; i < n; i++) sum += a + b;
    return sum;
}
const result = numberChain(5000000);
if (result !== 2500000.5) throw new Error('wrong result');
print(result);
