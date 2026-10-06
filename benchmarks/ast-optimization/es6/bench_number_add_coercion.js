function coercingAdd(n) {
    let result = 0;
    for (let i = 0; i < n; i++) {
        const value = i & 1 ? 's' : 0.25;
        result = value + value;
    }
    return result;
}
const result = coercingAdd(500000);
if (result !== 'ss') throw new Error('wrong result');
print(result);
