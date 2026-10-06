function mixedChain(n) {
    let sum = 0.5;
    for (let i = 0; i < n; i++) {
        const value = i & 1 ? 1 : 0.25;
        sum += value + value;
    }
    return sum;
}
const result = mixedChain(5000000);
if (result !== 6250000.5) throw new Error('wrong result');
print(result);
